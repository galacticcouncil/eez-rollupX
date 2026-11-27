"""First-network L1 lifecycle. Own resources by exact namespace and saved IDs."""
import base64
from contextlib import AbstractContextManager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import tempfile
import time

import yaml


ROOT = Path(__file__).resolve().parent
PREFIX = "eez-lark-1"
VOLUMES = tuple(f"{PREFIX}-686868-{role}" for role in ("genesis", "execution", "beacon", "validators"))
TOOL_SHA256 = "7593a0e7e2d14aed8ebb47f919c77dc73efdc2a15948be2a5ddfe934c9b6c37d"


class DeploymentError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise DeploymentError(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def fingerprint(service):
    fields = ('repository', 'ports', 'mounts', 'secrets', 'configs', 'hosts', 'variables',
              'labels', 'containerLabels', 'command', 'entrypoint', 'hostname', 'isolation',
              'sysctls', 'user', 'dir', 'tty', 'healthcheck', 'logdriver', 'resources')
    value = {key: service.get(key) for key in fields}
    value['networks'] = sorted((network.get('id'), network.get('networkName'))
                               for network in service.get('networks', []))
    value['deployment'] = {key: service.get('deployment', {}).get(key) for key in
                           ('update', 'restartPolicy', 'rollback', 'placement', 'maxReplicas')}
    return digest(value)


def private_write(path, text):
    with open(path, 'x', opener=lambda name, flags: os.open(name, flags, 0o600)) as stream:
        stream.write(text)


class State(AbstractContextManager):
    def __init__(self, directory, target, readonly=False):
        self.directory = directory.resolve()
        require(not self.directory.is_relative_to(ROOT.parents[2]), "keep Lark state and secrets outside the repository")
        self.directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        metadata = self.directory.stat()
        require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) & 0o077 == 0,
                "state directory must be owned by this user and private (chmod 700)")
        self.target = target
        self.readonly = readonly
        self.path = self.directory / 'state.json'

    def __enter__(self):
        self.lock = None
        try:
            if not self.readonly:
                self.lock = (self.directory / 'operation.lock').open('a')
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.data = json.loads(self.path.read_text()) if self.path.exists() else {
                'schema': 1, 'target': self.target, 'resources': {}, 'stacks': {}, 'services': {}}
            require(self.data.get('schema') == 1 and self.data.get('target') == self.target,
                    "saved Lark state belongs to another target or schema")
        except (BlockingIOError, OSError, ValueError, DeploymentError):
            if self.lock:
                self.lock.close()
            raise DeploymentError("state is busy, unreadable or belongs to another target") from None
        return self

    def save(self):
        require(not self.readonly, "read-only state cannot be modified")
        with tempfile.NamedTemporaryFile(mode='w', dir=self.directory, delete=False) as stream:
            json.dump(self.data, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(stream.name, self.path)

    def __exit__(self, *args):
        if self.lock:
            self.lock.close()


def job_spec(node, config, prepare):
    source = (ROOT / 'job.yml').read_text().replace(
        '${EEZ_LARK_DATA_NODE:?Select the persistent Lark data node}', node)
    spec = yaml.safe_load(source)
    job = spec['services']['job']
    job['configs'] = [{'source': 'script', 'target': '/job.sh'}]
    job['volumes'] = ['genesis:/public' + ('' if prepare else ':ro')]
    spec['configs'] = {'script': {'external': True, 'name': config}}
    spec['volumes'] = {'genesis': {'external': True, 'name': VOLUMES[0]}}
    if prepare:
        job['volumes'].append('validators:/validators')
        job['secrets'] = [{'source': 'mnemonic', 'target': 'validator-mnemonic'}]
        spec['volumes']['validators'] = {'external': True, 'name': VOLUMES[3]}
        spec['secrets'] = {'mnemonic': {'external': True, 'name': PREFIX + '-validator-mnemonic'}}
    else:
        job['networks'] = ['l1']
        spec['networks'] = {'l1': {'external': True, 'name': PREFIX + '_l1'}}
        job['deploy']['resources']['limits'] = {'cpus': '1.0', 'memory': '256M'}
    return spec


def receipt_from_logs(logs):
    lines = [item.get('line', '') for item in logs if isinstance(item, dict)]
    matches = [line.split('LARK_PREPARED ', 1)[1] for line in lines if 'LARK_PREPARED ' in line]
    require(len(matches) == 1, "preparation has no unique public receipt; inspect the retained EEZ task")
    try:
        receipt = json.loads(matches[0])
        require(isinstance(receipt, dict) and set(receipt) == {
            'schema', 'l1_chain_id', 'l2_chain_id', 'validators', 'treasury', 'genesis_sha256',
            'genesis_hash', 'genesis_time', 'genesis_validators_root'}, "unexpected preparation receipt fields")
        require(receipt['schema'] == 1 and receipt['l1_chain_id'] == 686868
                and receipt['l2_chain_id'] == 696969 and receipt['validators'] == 64,
                "preparation receipt has the wrong network profile")
        for key in ('genesis_hash', 'genesis_validators_root'):
            require(bool(re.fullmatch(r'0x[0-9a-fA-F]{64}', receipt[key])), "invalid preparation receipt hash")
        require(bool(re.fullmatch(r'[0-9a-f]{64}', receipt['genesis_sha256']))
                and type(receipt['genesis_time']) is int and receipt['genesis_time'] > 0,
                "invalid preparation receipt identity")
        require(bool(re.fullmatch(r'0x[0-9a-fA-F]{40}', receipt['treasury']))
                and int(receipt['treasury'], 16) != 0, "invalid preparation treasury")
    except (ValueError, TypeError, KeyError):
        raise DeploymentError("invalid public preparation receipt") from None
    return receipt


class Lifecycle:
    def __init__(self, api, state, render, timeout=3600):
        self.api, self.state, self.render, self.timeout = api, state, render, timeout

    @property
    def data(self):
        return self.state.data

    def validate_node(self, node):
        nodes = self.api.get('nodes')
        require(len(nodes) == 1 and nodes[0].get('id') == node
                and nodes[0].get('role') == 'manager' and nodes[0].get('state') == 'ready'
                and nodes[0].get('availability') == 'active' and nodes[0].get('arch') == 'x86_64',
                "L1 provisioning currently requires the selected single active amd64 manager")

    def claim(self, node, tool):
        self.validate_node(node)
        for kind, field in (('services', 'serviceName'), ('stacks', 'stackName'),
                            ('volumes', 'volumeName'), ('secrets', 'secretName'), ('networks', 'networkName')):
            require(not any(item.get(field, '') == PREFIX or item.get(field, '').startswith((PREFIX+'-', PREFIX+'_'))
                            for item in self.api.get(kind)),
                    "EEZ Lark resources already exist without this deployment state; refusing adoption")
        require(hashlib.sha256(tool.read_bytes()).hexdigest() == TOOL_SHA256,
                "validator tool does not match the pinned genesis image; run tools.sh")
        require(not any((self.state.directory / name).exists() for name in ('engine-jwt', 'validator-mnemonic')),
                "credential files exist without deployment state; inspect before recovery")
        try:
            result = subprocess.run([str(tool.resolve()), 'mnemonic'], capture_output=True, text=True, timeout=30)
        except subprocess.SubprocessError:
            raise DeploymentError("validator mnemonic generation did not complete") from None
        require(result.returncode == 0 and bool(re.fullmatch(r'(?:[a-z]+ ){23}[a-z]+', result.stdout.strip())),
                "pinned validator tool could not generate a fresh mnemonic")
        private_write(self.state.directory / 'validator-mnemonic', result.stdout.strip())
        private_write(self.state.directory / 'engine-jwt', secrets.token_hex(32))
        self.data.update(node_id=node, phase='credentials')
        self.state.save()

    def resource(self, kind, name, body):
        recorded = self.data['resources'].setdefault(kind, {})
        if name in recorded:
            require(recorded[name] != 'pending', "an earlier resource POST is inconclusive; inspect before retry")
            return
        # Persist intention before a mutation. A lost response must never cause blind retries.
        recorded[name] = 'pending'
        self.state.save()
        result = self.api.post(kind, body)
        identity = result.get('id') if isinstance(result, dict) else None
        require(identity is not None, "resource POST returned no identity; inspect before retry")
        recorded[name] = identity
        self.state.save()

    def config(self, filename):
        content = (ROOT / filename).read_bytes()
        name = PREFIX + '-' + filename.removesuffix('.sh') + '-' + hashlib.sha256(content).hexdigest()[:12]
        self.resource('configs', name, {'configName': name, 'data': base64.b64encode(content).decode()})
        return name

    def submit(self, name, spec):
        require(name == PREFIX or name.startswith(PREFIX + '-'), "unowned stack name")
        entry = self.data['stacks'].get(name)
        if entry:
            require(entry['status'] == 'submitted', "an earlier stack POST is inconclusive; inspect before retry")
            return
        self.data['stacks'][name] = {'status': 'pending', 'compose': spec}
        self.state.save()
        self.api.post('stacks', {'name': name, 'spec': {'compose': json.dumps(spec)}})
        self.data['stacks'][name]['status'] = 'submitted'
        self.state.save()

    def services(self, stack):
        services = self.api.get('stacks/' + stack + '/services')
        expected = {stack + '_' + role for role in self.data['stacks'][stack]['compose']['services']}
        require(all(item.get('stack') == stack and item.get('serviceName') in expected for item in services),
                "unexpected service in the EEZ stack")
        for item in services:
            name, identity = item['serviceName'], item['id']
            require(name not in self.data['services'] or self.data['services'][name] == identity,
                    "EEZ service identity changed; inspect before recovery")
            self.data['services'][name] = identity
        self.state.save()
        return services

    def wait_job(self, stack):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            services = self.services(stack)
            if len(services) == 1:
                tasks = self.api.get('services/' + services[0]['id'] + '/tasks')
                require(len(tasks) <= 1, "one-shot EEZ job has multiple attempts; inspect retained evidence")
                if tasks:
                    status = tasks[0].get('state')
                    require(status not in ('failed', 'rejected', 'shutdown', 'orphaned'),
                            "EEZ one-shot job failed; inspect Swarmpit and private preparation logs")
                    if status == 'complete':
                        return services[0]['id']
            time.sleep(5)
        raise DeploymentError("EEZ job is not complete; it remains retained and will not be resubmitted")

    def wait_runtime(self, expected):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            services = self.services(PREFIX)
            if len(services) == len(expected) and all(
                    item.get('replicas') == expected[item['serviceName'].split('_', 1)[1]]
                    and item.get('status', {}).get('tasks', {}).get('running') ==
                    expected[item['serviceName'].split('_', 1)[1]] for item in services):
                return
            time.sleep(5)
        raise DeploymentError("EEZ runtime did not converge; inspect retained tasks without resetting state")

    def bootstrap(self, node, tool):
        if 'node_id' not in self.data:
            self.claim(node, tool)
        require(self.data['node_id'] == node, "Lark data-node relocation is unsupported")
        self.validate_node(node)
        if self.data.get('phase') in ('ready', 'started', 'stopped'):
            return self.status()
        for name in ('engine-jwt', 'validator-mnemonic'):
            path = self.state.directory / name
            require(path.stat().st_uid == os.getuid() and stat.S_IMODE(path.stat().st_mode) & 0o077 == 0,
                    "credential files must be private and owned by this user")
            self.resource('secrets', PREFIX + '-' + name, {
                'secretName': PREFIX + '-' + name, 'data': base64.b64encode(path.read_bytes()).decode()})
        for volume in VOLUMES:
            self.resource('volumes', volume, {'volumeName': volume, 'driver': 'local', 'options': []})
        preparation = PREFIX + '-prepare'
        if preparation not in self.data['stacks']:
            config = self.config('prepare.sh')
            self.submit(preparation, job_spec(node, config, True))
        else:
            self.submit(preparation, self.data['stacks'][preparation]['compose'])
        print('Waiting for EEZ Lark genesis/validator preparation.', flush=True)
        identity = self.wait_job(preparation)
        receipt = receipt_from_logs(self.api.get('services/' + identity + '/logs?since=0'))
        self.data['receipt'] = receipt
        self.data['phase'] = 'prepared'
        self.state.save()
        self.submit(PREFIX, self.render(node, receipt['treasury']))
        print('Waiting for the three dedicated EEZ Lark L1 services.', flush=True)
        self.wait_runtime({'execution': 1, 'beacon': 1, 'validator': 1})
        current = {item['serviceName']: fingerprint(item) for item in self.services(PREFIX)}
        require('fingerprints' not in self.data or self.data['fingerprints'] == current,
                "EEZ runtime settings changed; reconcile operator edits before continuing")
        self.data['fingerprints'] = current
        self.state.save()
        if 'initial_check' not in self.data:
            self.data['initial_check'] = self.new_check()
            self.state.save()
        self.finish_check(self.data['initial_check'])
        self.data['phase'] = 'ready'
        self.state.save()
        return self.status()

    def new_check(self):
        counter = self.data.get('check_count', 0) + 1
        self.data['check_count'] = counter
        self.state.save()
        stamp = datetime.now(timezone.utc).strftime('%y%m%d%H%M')
        name = f'{PREFIX}-check-{stamp}-{counter}'
        config = self.config('check-l1.sh')
        self.submit(name, job_spec(self.data['node_id'], config, False))
        return name

    def finish_check(self, name):
        print('Waiting for EEZ Lark identity, head advancement and first finality.', flush=True)
        identity = self.wait_job(name)
        logs = self.api.get('services/' + identity + '/logs?since=0')
        require(any('LARK_L1_READY chain=686868 ' in item.get('line', '') for item in logs),
                "completed readiness job has no success marker")

    def check(self):
        require(PREFIX in self.data['stacks'], "bootstrap EEZ Lark before checking it")
        name = self.new_check()
        self.finish_check(name)
        self.data['phase'] = 'ready'
        self.state.save()
        return {'check': name, 'status': 'passed'}

    def scale(self, replicas):
        require(PREFIX in self.data['stacks'], "bootstrap EEZ Lark before changing its runtime replicas")
        self.validate_node(self.data['node_id'])
        entry = self.data['stacks'][PREFIX]
        saved = self.api.get('stacks/' + PREFIX + '/file')
        require(digest(yaml.safe_load(saved['spec']['compose'])) == digest(entry['compose']),
                "Swarmpit EEZ stack differs from saved state; reconcile operator edits before applying")
        require(set(entry['compose']['services']) == {'execution', 'beacon', 'validator'},
                "unexpected runtime roles; refusing a partial lifecycle operation")
        live = self.services(PREFIX)
        current = {item['serviceName']: fingerprint(item) for item in live}
        require(self.data.get('fingerprints') == current,
                "live EEZ runtime settings changed; reconcile operator edits before applying")
        require(all(item['replicas'] == entry['compose']['services'][item['serviceName'].split('_', 1)[1]]
                    ['deploy']['replicas'] for item in live),
                "live EEZ replica targets changed; reconcile operator edits before applying")
        order = ('execution', 'beacon', 'validator') if replicas else ('validator', 'beacon', 'execution')
        for role in order:
            if entry['compose']['services'][role]['deploy']['replicas'] != replicas:
                # Save the exact desired source before POST; it is also saved by Swarmpit.
                entry['compose']['services'][role]['deploy']['replicas'] = replicas
                self.state.save()
                self.api.post('stacks/' + PREFIX, {'name': PREFIX, 'spec': {'compose': json.dumps(entry['compose'])}})
            # A resumed phase may already have its desired count but still be stopping.
            expected = {name: spec['deploy']['replicas'] for name, spec in entry['compose']['services'].items()}
            self.wait_runtime(expected)
        self.data['phase'] = 'started' if replicas else 'stopped'
        self.state.save()
        return self.status()

    def status(self):
        return {'phase': self.data.get('phase', 'not provisioned'),
                'l1_chain_id': 686868, 'l2_chain_id': 696969,
                'receipt': self.data.get('receipt'),
                'services': [{'name': item.get('serviceName'), 'state': item.get('state'),
                              'replicas': item.get('replicas'), 'status': item.get('status', {}).get('tasks')}
                             for item in (self.api.get('stacks/' + PREFIX + '/services')
                                          if PREFIX in self.data['stacks'] else [])]}
