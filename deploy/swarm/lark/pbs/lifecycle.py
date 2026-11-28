"""Persistent EEZ PBS provisioning; private signing stays on the operator machine."""
import base64
import copy
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import time

import yaml

from lifecycle import ROOT, PREFIX, Lifecycle, DeploymentError, digest, fingerprint, job_spec, private_write, require

RELAY = PREFIX + '-pbs'
BUILDER = PREFIX + '-builder'
CAST_SHA256 = 'ccd95a4607ca3ebfcb88bb90e7235cdb7f0564f5f1afa17478d5fccabbb222cb'
PBS_VOLUMES = tuple(f'{PREFIX}-686868-{role}' for role in ('postgres', 'redis', 'pbs', 'builder', 'builder-beacon'))
UP = ((PREFIX, 'execution'), (PREFIX, 'beacon'), (RELAY, 'postgres'), (RELAY, 'redis'),
      (RELAY, 'relay-housekeeper'), (RELAY, 'relay-api'), (BUILDER, 'builder'),
      (BUILDER, 'builder-beacon'), (BUILDER, 'mev-boost'), (PREFIX, 'validator'))
DOWN = ((PREFIX, 'validator'), (BUILDER, 'mev-boost'), (BUILDER, 'builder-beacon'),
        (BUILDER, 'builder'), (RELAY, 'relay-api'), (RELAY, 'relay-housekeeper'),
        (RELAY, 'redis'), (RELAY, 'postgres'), (PREFIX, 'beacon'), (PREFIX, 'execution'))


def public_record(logs, marker):
    matches = [line['line'].split(marker+' ', 1)[1] for line in logs
               if isinstance(line, dict) and marker+' ' in line.get('line', '')]
    require(len(matches) == 1, 'job has no unique public result; inspect its retained task')
    try:
        result = json.loads(matches[0])
        require(isinstance(result, dict) and result.get('schema') == 1, 'invalid public job result schema')
    except (ValueError, TypeError):
        raise DeploymentError('job returned invalid public JSON') from None
    return result


def load_stack(filename, node, replacements=()):
    require(bool(re.fullmatch(r'[a-z0-9]{25}', node)), 'invalid PBS data-node ID')
    text = (ROOT/'pbs'/filename).read_text().replace(
        '${EEZ_LARK_DATA_NODE:?Select the persistent Lark data node}', node)
    placeholders = set(re.findall(r'__[A-Z_]+__',text))
    for key, value in replacements:
        text = text.replace(key, value)
    require('${' not in text and not any(key in text for key in placeholders), 'unresolved PBS runtime input')
    return yaml.safe_load(text)


def quantity(value):
    require(isinstance(value, str) and bool(re.fullmatch(r'0x[0-9a-fA-F]{1,64}', value)),
            'invalid Ethereum quantity in public snapshot')
    return int(value, 16)


class PbsLifecycle(Lifecycle):
    @property
    def pbs(self):
        return self.data['pbs']

    def cast(self, tool, *args):
        # Explicit wallet/chain/fee flags take precedence over unrelated operator env.
        env = {key:value for key,value in os.environ.items()
               if not key.startswith(('ETH_', 'FOUNDRY_', 'DAPP_')) and key not in ('CHAIN', 'PRIVATE_KEY')}
        env['RUST_LOG'] = 'error'
        try:
            result = subprocess.run([str(tool.resolve()), *args], capture_output=True, text=True,
                                    timeout=30, cwd=self.state.directory, env=env)
        except (OSError, subprocess.SubprocessError):
            raise DeploymentError('pinned Foundry operation did not complete') from None
        require(result.returncode == 0, 'pinned Foundry operation failed; no private output was logged')
        return result.stdout.strip()

    def private_file(self, name):
        path = self.state.directory/name
        metadata = path.stat()
        require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) & 0o077 == 0,
                'PBS credential files must remain private and owned by this user')
        return path.read_text().strip()

    def secret(self, name):
        value = self.private_file(name)
        self.resource('secrets', PREFIX+'-'+name, {
            'secretName':PREFIX+'-'+name, 'data':base64.b64encode(value.encode()).decode()})

    def claim_pbs(self):
        require(self.data.get('phase') == 'ready', 'qualify L1 with l1-check before adding PBS')
        self.verify_stack(PREFIX)
        base = self.data['stacks'][PREFIX]['compose']['services']
        require(not any(arg.startswith('--builder=') for arg in base['beacon']['command'])
                and '--builder-proposals' not in base['validator']['command'],
                'L1 already has unrecorded builder settings; reconcile before installing PBS')
        for name in ('builder-wallet.json','postgres-password','relay-password','relay-signing-key',
                     'builder-bls-key','builder-engine-jwt','builder-config'):
            require(not (self.state.directory/name).exists(),
                    'PBS credential files exist without ownership state; inspect before adoption')
        for kind, field in (('stacks','stackName'), ('services','serviceName'),
                            ('volumes','volumeName'), ('secrets','secretName'), ('networks','networkName')):
            recorded = set(self.data['stacks']) if kind == 'stacks' else set(self.data['services']) if kind == 'services' \
                else set(self.data['resources'].get(kind, {}))
            for item in self.api.get(kind):
                name = item.get(field, '')
                owned = name == PREFIX or name.startswith((PREFIX+'-', PREFIX+'_'))
                # The base L1 overlay is already owned by the original stack.
                known_network = kind == 'networks' and item.get('stack') in self.data['stacks']
                require(not owned or name in recorded or name == PREFIX+'_l1' or known_network,
                        'unknown EEZ resources exist; refusing PBS resource adoption')
        backup = self.state.directory/'state-before-pbs.json'
        if backup.exists():
            require(digest(json.loads(backup.read_text())) == digest(self.data),
                    'existing pre-PBS state backup differs; inspect before recovery')
        else:
            private_write(backup,json.dumps(self.data,indent=2)+'\n')
        self.data['schema'] = 2  # Old L1-only helpers must reject PBS dependency state.
        self.data['pbs'] = {'phase':'credentials', 'jobs':{}, 'transactions':{}}
        self.state.save()

    def credentials(self, tool):
        wallet = self.state.directory/'builder-wallet.json'
        if not wallet.exists():
            raw = json.loads(self.cast(tool, 'wallet', 'new', '--json'))
            entry = raw[0] if isinstance(raw, list) and len(raw) == 1 else raw
            require(isinstance(entry, dict) and
                    bool(re.fullmatch(r'0x[0-9a-fA-F]{64}', entry.get('private_key',''))) and
                    bool(re.fullmatch(r'0x[0-9a-fA-F]{40}', entry.get('address',''))), 'invalid generated builder wallet')
            private_write(wallet, json.dumps(entry))
        entry = json.loads(self.private_file('builder-wallet.json'))
        self.pbs['builder_address'] = entry['address'].lower()
        for name in ('postgres-password', 'relay-password', 'relay-signing-key', 'builder-bls-key', 'builder-engine-jwt'):
            path = self.state.directory/name
            if not path.exists():
                # 248 random bits are below the BLS scalar modulus and provide ample entropy.
                value = '00'+secrets.token_hex(31) if name.endswith('key') else secrets.token_hex(32)
                require(int(value,16) > 0, 'invalid zero credential entropy')
                private_write(path, value)
            require(bool(re.fullmatch(r'[0-9a-f]{64}', self.private_file(name))), 'invalid private PBS credential format')
        self.pbs['phase'] = 'provisioning'
        self.state.save()

    def public_config(self, label, value):
        content = json.dumps(value, sort_keys=True).encode()
        name = PREFIX+'-'+label+'-'+hashlib.sha256(content).hexdigest()[:12]
        self.resource('configs', name, {'configName':name, 'data':base64.b64encode(content).decode()})
        return name

    def run_job(self, step, filename, value=None, *, databases=False, bindings=False):
        name = self.pbs['jobs'].get(step)
        if not name:
            name = PREFIX+'-pbs-'+step
            self.pbs['jobs'][step] = name
            self.state.save()
        if name not in self.data['stacks']:
            config = self.config('pbs/'+filename)
            spec = job_spec(self.data['node_id'], config, False)
            job = spec['services']['job']
            if databases:
                job['image'] = load_stack('relay.yml', self.data['node_id'])['services']['postgres']['image']
                job.pop('volumes')
                spec.pop('volumes')
                job['networks'] = ['relay']
                spec['networks'] = {'relay':{'external':True, 'name':RELAY+'_relay'}}
                job['secrets'] = [{'source':'relay_password', 'target':'relay-password'}]
                spec['secrets'] = {'relay_password':{'external':True, 'name':PREFIX+'-relay-password'}}
            else:
                rpc = self.config('pbs/rpc.sh')
                data = self.public_config(step+'-input', value or {})
                job['configs'] += [{'source':'rpc','target':'/rpc.sh'}, {'source':'input','target':'/input.json'}]
                spec['configs'].update(rpc={'external':True,'name':rpc}, input={'external':True,'name':data})
            if bindings:
                job['volumes'].append('pbs:/pbs')
                spec['volumes']['pbs'] = {'external':True,'name':PREFIX+'-686868-pbs'}
            self.submit(name, spec)
        else:
            self.submit(name, self.data['stacks'][name]['compose'])
        identity = self.wait_job(name)
        return self.api.get('services/'+identity+'/logs?since=1970-01-01T00:00:00Z')

    def relay_key(self):
        if 'relay_public_key' in self.pbs:
            return self.pbs['relay_public_key']
        deadline = time.monotonic()+self.timeout
        while time.monotonic() < deadline:
            service = next(item for item in self.services(RELAY) if item['serviceName'] == RELAY+'_relay-api')
            logs = self.api.get('services/'+service['id']+'/logs?since=1970-01-01T00:00:00Z')
            keys = {value.lower() for item in logs if 'Using BLS key' in item.get('line','')
                    for value in re.findall(r'0x[0-9a-fA-F]{96}', item['line'])}
            require(len(keys) <= 1, 'relay has conflicting public signing identities')
            if keys:
                self.pbs['relay_public_key'] = keys.pop()
                self.state.save()
                return self.pbs['relay_public_key']
            time.sleep(2)
        raise DeploymentError('relay public signing identity did not become available')

    def initial_stack(self, name, spec):
        self.submit(name, spec)
        if 'fingerprints' not in self.data['stacks'][name]:
            self.remember_stack(name)
        else:
            self.verify_stack(name)

    def transaction(self, name, tool, amount):
        if name in self.pbs['transactions']:
            return self.pbs['transactions'][name]
        logs = self.run_job(name+'-snapshot', 'snapshot.sh')
        snapshot = public_record(logs, 'LARK_PBS_SNAPSHOT')
        sender = self.data['receipt']['treasury'].lower()
        require(snapshot.get('treasury','').lower() == sender, 'snapshot treasury does not match genesis')
        nonce, balance, base_fee = (quantity(snapshot.get(key)) for key in ('nonce','balance','base_fee'))
        require(nonce < 2**64, 'treasury nonce is outside Ethereum range')
        gas_price = 2*base_fee+2_000_000_000
        require(balance >= amount+21000*gas_price, 'private Lark treasury cannot cover this PBS transaction')
        wallet = ['--mnemonic', str(self.state.directory/'validator-mnemonic'),
                  '--mnemonic-derivation-path', "m/44'/60'/0'/0/0"]
        require(self.cast(tool,'wallet','address',*wallet).lower() == sender, 'private treasury mnemonic does not match genesis')
        raw = self.cast(tool,'mktx','--legacy','--chain','686868','--nonce',str(nonce),
                        '--gas-limit','21000','--gas-price',str(gas_price),'--value',str(amount),
                        '--rpc-url','http://127.0.0.1:1','--rpc-timeout','1',*wallet,
                        self.pbs['builder_address'])
        require(bool(re.fullmatch(r'0x[0-9a-f]+',raw)) and len(raw)>130, 'invalid signed PBS transaction')
        tx_hash = self.cast(tool,'keccak',raw)
        require(bool(re.fullmatch(r'0x[0-9a-f]{64}',tx_hash)), 'invalid PBS transaction hash')
        result = {'sender':sender,'builder_address':self.pbs['builder_address'],
                  'nonce':hex(nonce),'value':hex(amount),'raw':raw,'hash':tx_hash}
        self.pbs['transactions'][name] = result
        self.state.save()  # Bind the exact nonce/bytes/hash before any remote submission.
        return result

    def transition(self, stack, name, change):
        operation = self.pbs.get(name)
        if operation and operation['status'] == 'confirmed':
            return
        if not operation:
            entry = self.verify_stack(stack)
            spec = copy.deepcopy(entry['compose'])
            change(spec)
            live = self.services(stack)
            for item in live:
                role = item['serviceName'].split('_',1)[1]
                if 'command' in spec['services'][role]:
                    item['command'] = spec['services'][role]['command']
            operation = {'compose':spec, 'fingerprints':{s['serviceName']:fingerprint(s) for s in live},
                         'status':'pending'}
            self.pbs[name] = operation
            self.state.save()
            if digest(spec) != digest(entry['compose']):
                self.api.post('stacks/'+stack, {'name':stack,'spec':{'compose':json.dumps(spec)}})
        # A lost response is reconciled against the exact saved intent, never re-POSTed.
        saved = self.api.get('stacks/'+stack+'/file')
        require(digest(yaml.safe_load(saved['spec']['compose'])) == digest(operation['compose']),
                'PBS configuration transition is inconclusive; inspect the EEZ stack')
        self.data['stacks'][stack]['compose'] = operation['compose']
        self.state.save()
        self.wait_stack(stack,{role:s['deploy']['replicas'] for role,s in operation['compose']['services'].items()})
        require({s['serviceName']:fingerprint(s) for s in self.services(stack)} == operation['fingerprints'],
                'live runtime differs from the authorized PBS configuration transition')
        self.data['stacks'][stack]['fingerprints'] = operation['fingerprints']
        if stack == PREFIX:
            self.data['fingerprints'] = operation['fingerprints']
        operation['status'] = 'confirmed'
        self.state.save()

    def enable_builder_proposals(self):
        def change(spec):
            spec['services']['beacon']['command'].append('--builder=http://mev-boost:18550')
            spec['services']['validator']['command'].append('--builder-proposals')
        self.transition(PREFIX,'enable',change)

    def enable_peer_discovery(self):
        def change(spec):
            command = spec['services']['beacon']['command']
            command[:] = [arg for arg in command if arg != '--disable-discovery']
            command += ['--enr-address=beacon','--disable-enr-auto-update']
        self.transition(PREFIX,'peer_discovery',change)

    def configure_builder_peer(self, enr):
        def change(spec):
            command = spec['services']['builder-beacon']['command']
            spec['services']['builder-beacon']['command'] = [
                '--boot-nodes='+enr if arg.startswith('--boot-nodes=') else arg for arg in command]
        self.transition(BUILDER,'builder_peer_discovery',change)

    def bootstrap_pbs(self, tool):
        if self.data.get('pbs',{}).get('qualified') and self.pbs.get('phase') in ('ready','started','stopped'):
            return self.status()
        require(hashlib.sha256(tool.read_bytes()).hexdigest() == CAST_SHA256,
                'Foundry binary does not match the pinned 1.7.1 tool; run tools.sh with a deploy-tool image')
        self.validate_node(self.data['node_id'])
        if 'pbs' not in self.data:
            self.claim_pbs()
        self.credentials(tool)
        for name in ('postgres-password','relay-password','relay-signing-key','builder-engine-jwt'):
            self.secret(name)
        for name in PBS_VOLUMES:
            self.resource('volumes',name,{'volumeName':name,'driver':'local','options':[]})
        relay = load_stack('relay.yml',self.data['node_id'])
        relay['configs'] = {
            'relay_start':{'external':True,'name':self.config('../components/pbs/relay-start.sh')},
            'postgres_init':{'external':True,'name':self.config('../components/pbs/provision-relay.sh')}}
        self.initial_stack(RELAY,relay)
        print('Starting dedicated EEZ relay PostgreSQL/Redis.',flush=True)
        for role in ('postgres','redis'):
            self.scale_role(RELAY,role,1)
        logs = self.run_job('databases','databases.sh',databases=True)
        require(any('LARK_PBS_DATABASES_READY' in item.get('line','') for item in logs), 'database probe has no success marker')
        for role in ('relay-housekeeper','relay-api'):
            self.scale_role(RELAY,role,1)
        relay_key = self.relay_key()
        self.enable_builder_proposals()
        self.enable_peer_discovery()
        peer = public_record(self.run_job('peer-info','peer-info.sh'),'LARK_BEACON_PEER')
        enr = peer.get('beacon_enr','')
        require(bool(re.fullmatch(r'enr:[a-zA-Z0-9_-]{64,2048}',enr)), 'invalid canonical beacon ENR')
        logs = self.run_job('bindings','bindings.sh',{'relay_public_key':relay_key},bindings=True)
        bindings = public_record(logs,'LARK_PBS_BINDINGS')
        match = re.fullmatch(r'enode://[0-9a-f]{128}@([0-9.]+):30303',bindings.get('execution_peer',''))
        require(match is not None, 'invalid execution peer binding')
        ipaddress.IPv4Address(match[1])
        require(bool(re.fullmatch(r'/dns4/beacon/tcp/9000/p2p/[a-zA-Z0-9]+',bindings.get('beacon_peer','')))
                and bool(re.fullmatch(r'0x[0-9a-fA-F]{8}',bindings.get('genesis_fork','')))
                and bindings.get('genesis_time') == self.data['receipt']['genesis_time'], 'invalid beacon/genesis bindings')
        require(bindings['beacon_peer'].endswith('/'+peer.get('peer_id','')), 'canonical beacon identity changed')
        self.pbs['bindings'] = bindings
        self.state.save()
        config_path = self.state.directory/'builder-config'
        if not config_path.exists():
            wallet = json.loads(self.private_file('builder-wallet.json'))
            text = (ROOT/'pbs/builder.template.toml').read_text()
            for name,value in [('__COINBASE_KEY__',wallet['private_key'].removeprefix('0x')),
                               ('__BUILDER_BLS_KEY__',self.private_file('builder-bls-key')),
                               ('__RELAY_PUBLIC_KEY__',relay_key),('__GENESIS_FORK__',bindings['genesis_fork'])]:
                text = text.replace(name,value)
            require('__' not in text, 'unresolved private builder configuration')
            private_write(config_path,text)
        self.secret('builder-config')
        builder = load_stack('builder.yml',self.data['node_id'],(
            ('__EXECUTION_PEER__',bindings['execution_peer']),('__BEACON_PEER__',bindings['beacon_peer']),
            ('__BEACON_ENR__',enr),
            ('__TREASURY__',self.data['receipt']['treasury'])))
        builder['configs'] = {'boost_start':{'external':True,'name':self.config('../components/pbs/boost-start.sh')}}
        self.initial_stack(BUILDER,builder)
        self.configure_builder_peer(enr)
        print('Funding the fresh builder wallet with private-chain test ETH.',flush=True)
        funding = self.transaction('funding',tool,1000*10**18)
        funded = public_record(self.run_job('funding','fund.sh',funding),'LARK_PBS_FUNDED')
        require(funded.get('hash') == funding['hash'], 'funding receipt belongs to another transaction')
        self.pbs['funding'] = funded
        self.state.save()
        for role in ('builder','builder-beacon','mev-boost'):
            self.scale_role(BUILDER,role,1)
        print('Enabling EEZ builder proposals and validating a single-target private bundle.',flush=True)
        self.enable_builder_proposals()
        self.transaction('canary',tool,10**16)
        return self.qualify_canary('canary')

    def qualify_canary(self, step):
        transaction = self.pbs['transactions']['canary']
        proof = public_record(self.run_job(step,'canary.sh',transaction),'LARK_PBS_CANARY')
        require(proof.get('hash') == transaction['hash'] and proof.get('chain_id') == 686868
                and proof.get('builder_address','').lower() == self.pbs['builder_address'], 'wrong PBS canary identity')
        self.pbs['canary'] = proof
        self.pbs['phase'] = 'ready'
        self.pbs['qualified'] = True
        self.state.save()
        return self.status()

    def retry_canary(self):
        require('pbs' in self.data, 'bootstrap PBS before canary recovery')
        if self.pbs.get('qualified'):
            return self.status()
        require(self.pbs.get('builder_peer_discovery',{}).get('status') == 'confirmed',
                'finish PBS peer configuration before canary recovery')
        for stack in (PREFIX,RELAY,BUILDER):
            self.verify_stack(stack)
        if 'canary-recovery' not in self.pbs['jobs']:
            original = self.pbs['jobs'].get('canary')
            require(original is not None, 'no original canary attempt to recover')
            service = self.services(original)[0]
            tasks = self.api.get('services/'+service['id']+'/tasks')
            require(len(tasks) == 1 and tasks[0].get('state') == 'failed',
                    'original canary must have conclusively failed before recovery')
            logs = self.api.get('services/'+service['id']+'/logs?since=1970-01-01T00:00:00Z')
            lines = [item.get('line','') for item in logs]
            require(any('Builder/relay/validator registration did not become ready.' in line for line in lines)
                    and not any('LARK_PBS_BUNDLE' in line for line in lines),
                    'only a confirmed pre-submission readiness failure permits this recovery')
            self.pbs['canary_recovery'] = {'original_job':original,
                'hash':self.pbs['transactions']['canary']['hash'],'reason':'pre-submission readiness timeout'}
            self.state.save()
        return self.qualify_canary('canary-recovery')

    def all_scale(self, replicas):
        if not self.data.get('pbs'):
            return self.scale(replicas)
        require(self.pbs.get('enable',{}).get('status') == 'confirmed',
                'resume bootstrap-pbs to reconcile its proposal transition before lifecycle changes')
        require(not replicas or self.pbs.get('qualified'), 'finish PBS bootstrap before starting it')
        self.validate_node(self.data['node_id'])
        changing = False
        for stack in (PREFIX,RELAY,BUILDER):
            if stack in self.data['stacks']:
                entry = self.verify_stack(stack)
                changing |= any(s['deploy']['replicas'] != replicas for s in entry['compose']['services'].values())
                self.wait_stack(stack,{role:s['deploy']['replicas']
                                       for role,s in entry['compose']['services'].items()})
        for stack,role in (UP if replicas else DOWN):
            if stack in self.data['stacks']:
                self.scale_role(stack,role,replicas)
        self.data['phase'] = 'started' if replicas else 'stopped'
        self.pbs['phase'] = 'started' if replicas else 'stopped'
        if replicas and changing:
            self.pbs['start_count'] = self.pbs.get('start_count',0)+1
        self.state.save()
        return self.status()

    def probe(self, tool):
        require(self.data.get('pbs',{}).get('qualified'), 'qualify PBS before a post-start probe')
        require(hashlib.sha256(tool.read_bytes()).hexdigest() == CAST_SHA256, 'use the pinned Foundry tool')
        for stack in (PREFIX,RELAY,BUILDER):
            entry = self.verify_stack(stack)
            require(all(s['deploy']['replicas'] == 1 for s in entry['compose']['services'].values()),
                    'start the whole EEZ stack before probing PBS')
        step = 'probe-'+str(self.pbs.get('start_count',0))
        if step in self.pbs.get('probes',{}):
            return {'probe':self.pbs['probes'][step],'retained':True}
        transaction = self.transaction(step,tool,10**16)
        proof = public_record(self.run_job(step,'canary.sh',transaction),'LARK_PBS_CANARY')
        require(proof.get('hash') == transaction['hash'] and proof.get('chain_id') == 686868
                and proof.get('builder_address','').lower() == self.pbs['builder_address']
                and proof.get('builder_public_key') == self.pbs['canary']['builder_public_key'],
                'post-start probe does not match the qualified builder identity')
        self.pbs.setdefault('probes',{})[step] = proof
        self.state.save()
        return {'probe':proof,'retained':False}

    def pbs_check(self):
        require('canary' in self.pbs, 'qualify the PBS canary before a read-only check')
        self.check()
        counter = self.pbs.get('check_count',0)+1
        self.pbs['check_count'] = counter
        self.state.save()
        stamp = datetime.now(timezone.utc).strftime('%y%m%d%H%M')
        value = {**self.pbs['transactions']['canary'], **self.pbs['canary']}
        logs = self.run_job(f'check-{stamp}-{counter}','check.sh',value)
        proof = public_record(logs,'LARK_PBS_READY')
        require(proof.get('hash') == self.pbs['canary']['hash'], 'wrong retained PBS canary')
        self.data['phase'] = self.pbs['phase'] = 'ready'
        self.state.save()
        return {'phase':'ready','pbs':proof}

    def diagnose(self):
        require('pbs' in self.data, 'PBS must be provisioned before peer diagnostics')
        counter = self.pbs.get('diagnostic_count',0)+1
        self.pbs['diagnostic_count'] = counter
        self.state.save()
        logs = self.run_job('diagnose-'+str(counter),'diagnose.sh')
        return {'operation':'read-only chain and peer diagnostics',
                'lines':[item['line'] for item in logs if isinstance(item,dict) and 'line' in item]}

    def status(self):
        result = super().status()
        if self.data.get('pbs'):
            result['pbs'] = {key:self.pbs.get(key) for key in ('phase','builder_address','relay_public_key','funding','canary')}
            for stack in (RELAY,BUILDER):
                if stack in self.data['stacks']:
                    result['services'] += [{'name':s['serviceName'],'state':s.get('state'),
                                            'replicas':s.get('replicas'),'status':s.get('status',{}).get('tasks')}
                                           for s in self.api.get('stacks/'+stack+'/services')]
        return result
