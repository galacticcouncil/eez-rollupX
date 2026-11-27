"""Exercise namespace isolation, durable claims and lifecycle with a fake API."""
from contextlib import redirect_stdout
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lifecycle as life

NODE = 'a' * 25
RECEIPT = dict(schema=1, l1_chain_id=686868, l2_chain_id=696969, validators=64,
               treasury='0x' + '12' * 20, genesis_sha256='3' * 64,
               genesis_hash='0x' + '4' * 64, genesis_time=1,
               genesis_validators_root='0x' + '5' * 64)


class FakeApi:
    def __init__(self):
        self.serial = 0
        self.writes = []
        self.stackfiles = {}
        self.items = {'services': [{'id': 'z'*25, 'stack': 'unrelated', 'serviceName': 'unrelated_web'}],
                      'nodes': [dict(id=NODE, role='manager', state='ready', availability='active', arch='x86_64')],
                      'volumes': [], 'secrets': [], 'networks': [], 'stacks': [{'stackName': 'unrelated'}]}
        self.failed_job = False

    def get(self, path):
        if path in self.items:
            return copy.deepcopy(self.items[path])
        if path.startswith('stacks/') and path.endswith('/services'):
            return copy.deepcopy([s for s in self.items['services'] if s['stack'] == path.split('/')[1]])
        if path.startswith('services/'):
            service = next(s for s in self.items['services'] if s['id'] == path.split('/')[1])
            assert service['stack'].startswith(life.PREFIX)
            if path.endswith('/tasks'):
                return [{'state': 'failed' if self.failed_job else 'complete'}]
            if '-prepare' in service['stack']:
                return [{'line': 'LARK_PREPARED ' + json.dumps(RECEIPT)}]
            return [{'line': 'LARK_L1_READY chain=686868 head=0x10 finalized=0x8'}]
        if path.endswith('/file'):
            return {'spec': {'compose': json.dumps(self.stackfiles[path.split('/')[1]])}}
        raise AssertionError('unexpected API GET: ' + path)

    def post(self, path, body):
        self.writes.append((path, copy.deepcopy(body)))
        self.serial += 1
        identity = f'{self.serial:025d}'
        if path in ('volumes', 'secrets', 'configs'):
            field = {'volumes': 'volumeName', 'secrets': 'secretName', 'configs': 'configName'}[path]
            if path in self.items:
                self.items[path].append({field: body[field], 'id': identity})
            return {'id': identity}
        assert path == 'stacks' or path.startswith('stacks/' + life.PREFIX)
        name, spec = body['name'], json.loads(body['spec']['compose'])
        self.stackfiles[name] = spec
        if not any(s['stackName'] == name for s in self.items['stacks']):
            self.items['stacks'].append({'stackName': name})
        for role, service in spec['services'].items():
            service_name = name + '_' + role
            existing = next((s for s in self.items['services'] if s['serviceName'] == service_name), None)
            if existing is None:
                self.serial += 1
                existing = {'id': f'{self.serial:025d}', 'serviceName': service_name, 'stack': name}
                self.items['services'].append(existing)
            count = service['deploy']['replicas']
            existing.update(replicas=count, status={'tasks': {'running': count}},
                            repository={'image': service['image']}, command=service.get('command'))


def runtime(node, recipient):
    return {'version': '3.8', 'services': {role: {
        'image': 'example@sha256:' + 'f'*64, 'command': [node, recipient],
        'deploy': {'replicas': 1}} for role in ('execution', 'beacon', 'validator')}}


class LifecycleTest(unittest.TestCase):
    def bootstrap(self, state, api):
        tool = state.directory / 'tool'
        tool.write_text('test binary')
        with patch.object(life, 'TOOL_SHA256', hashlib.sha256(tool.read_bytes()).hexdigest()), \
                patch.object(life.subprocess, 'run', return_value=subprocess.CompletedProcess(
                    [], 0, ' '.join(['example'] * 24))), redirect_stdout(io.StringIO()) as output:
            result = life.Lifecycle(api, state, runtime, 30).bootstrap(NODE, tool)
        self.assertNotIn('example example', output.getvalue())
        return result

    def test_bootstrap_resume_and_ordered_stop_start_preserve_unrelated_resources(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            unrelated = copy.deepcopy(api.items['services'][0])
            self.assertEqual(self.bootstrap(state, api)['phase'], 'ready')
            before = len(api.writes)
            self.assertEqual(life.Lifecycle(api, state, runtime).bootstrap(NODE, Path('/missing'))['phase'], 'ready')
            self.assertEqual(len(api.writes), before)
            for file in ('validator-mnemonic', 'engine-jwt', 'state.json'):
                self.assertEqual((state.directory / file).stat().st_mode & 0o777, 0o600)
            operator = life.Lifecycle(api, state, runtime, 30)
            self.assertEqual(operator.scale(0)['phase'], 'stopped')
            counts = [{role: s['deploy']['replicas'] for role, s in json.loads(body['spec']['compose'])['services'].items()}
                      for path, body in api.writes[before:]]
            self.assertEqual(counts, [dict(execution=1, beacon=1, validator=0),
                                      dict(execution=1, beacon=0, validator=0),
                                      dict(execution=0, beacon=0, validator=0)])
            self.assertEqual(operator.scale(1)['phase'], 'started')
            self.assertEqual(api.items['services'][0], unrelated)
            for kind, body in api.writes:
                field = {'volumes': 'volumeName', 'secrets': 'secretName', 'configs': 'configName'}.get(kind, 'name')
                self.assertTrue(body[field].startswith(life.PREFIX))

    def test_existing_resources_are_never_adopted_or_overwritten(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            api.items['volumes'].append({'volumeName': life.VOLUMES[0]})
            with self.assertRaisesRegex(life.DeploymentError, 'refusing adoption'):
                life.Lifecycle(api, state, runtime).bootstrap(NODE, Path('/missing'))
            self.assertEqual(api.writes, [])

    def test_existing_namespace_network_blocks_creation_before_credentials(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            api.items['networks'].append({'networkName':life.PREFIX+'_l1'})
            with self.assertRaisesRegex(life.DeploymentError, 'refusing adoption'):
                life.Lifecycle(api, state, runtime).bootstrap(NODE, Path('/missing'))
            self.assertEqual(api.writes, [])
            self.assertFalse((Path(directory)/'validator-mnemonic').exists())

    def test_inconclusive_mutation_is_persisted_and_never_retried_blindly(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            operator = life.Lifecycle(api, state, runtime)
            with patch.object(api, 'post', side_effect=TimeoutError):
                with self.assertRaises(TimeoutError):
                    operator.resource('volumes', life.VOLUMES[0], {})
            self.assertEqual(json.loads(state.path.read_text())['resources']['volumes'][life.VOLUMES[0]], 'pending')
            with self.assertRaisesRegex(life.DeploymentError, 'inconclusive'):
                operator.resource('volumes', life.VOLUMES[0], {})
            self.assertEqual(api.writes, [])

    def test_operator_stack_and_live_service_edits_block_reapplication(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            self.bootstrap(state, api)
            before = len(api.writes)
            spec = api.stackfiles[life.PREFIX]
            spec['services']['execution']['command'] = ['operator-setting']
            with self.assertRaisesRegex(life.DeploymentError, 'operator edits'):
                life.Lifecycle(api, state, runtime).scale(0)
            api.stackfiles[life.PREFIX] = copy.deepcopy(state.data['stacks'][life.PREFIX]['compose'])
            service = next(s for s in api.items['services'] if s.get('stack') == life.PREFIX)
            service['variables'] = [{'name': 'OPERATOR', 'value': 'setting'}]
            with self.assertRaisesRegex(life.DeploymentError, 'operator edits'):
                life.Lifecycle(api, state, runtime).scale(0)
            self.assertEqual(len(api.writes), before)

    def test_failed_job_is_retained_and_cannot_become_success(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            api.failed_job = True
            with self.assertRaisesRegex(life.DeploymentError, 'one-shot job failed'):
                self.bootstrap(state, api)
            self.assertNotIn(life.PREFIX, state.data['stacks'])
            writes = len(api.writes)
            with self.assertRaisesRegex(life.DeploymentError, 'one-shot job failed'):
                life.Lifecycle(api, state, runtime).bootstrap(NODE, Path('/missing'))
            self.assertEqual(len(api.writes), writes)

    def test_resumed_stop_waits_for_validator_exit_before_stopping_beacon(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            self.bootstrap(state, api)
            state.data['stacks'][life.PREFIX]['compose']['services']['validator']['deploy']['replicas'] = 0
            api.stackfiles[life.PREFIX]['services']['validator']['deploy']['replicas'] = 0
            validator = next(s for s in api.items['services'] if s['serviceName'] == life.PREFIX+'_validator')
            validator['replicas'] = 0
            before = len(api.writes)
            def exit_validator(_):
                self.assertEqual(len(api.writes), before)
                validator['status']['tasks']['running'] = 0
            with patch.object(life.time, 'sleep', side_effect=exit_validator) as pause:
                self.assertEqual(life.Lifecycle(api, state, runtime, 30).scale(0)['phase'], 'stopped')
                pause.assert_called_once()

    def test_out_of_band_replica_changes_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory), 'target') as state:
            api = FakeApi()
            self.bootstrap(state, api)
            service = next(s for s in api.items['services'] if s.get('stack') == life.PREFIX)
            service['replicas'] = 0
            before = len(api.writes)
            with self.assertRaisesRegex(life.DeploymentError, 'replica targets changed'):
                life.Lifecycle(api, state, runtime, 30).scale(0)
            self.assertEqual(len(api.writes), before)

    def test_jobs_share_only_their_required_data_and_secrets(self):
        preparation = life.job_spec(NODE, 'example', True)
        probe = life.job_spec(NODE, 'example', False)
        self.assertNotIn('networks', preparation['services']['job'])
        self.assertEqual(probe['services']['job']['volumes'], ['genesis:/public:ro'])
        self.assertNotIn('secrets', probe)
        self.assertNotIn('validators', probe['volumes'])
        for spec in (preparation, probe):
            self.assertEqual(spec['services']['job']['deploy']['restart_policy']['condition'], 'none')

    def test_state_is_bound_to_target_and_serializes_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with life.State(path, 'target') as state:
                state.save()
                with life.State(path, 'target', readonly=True) as reader:
                    self.assertEqual(reader.data, state.data)
                    with self.assertRaisesRegex(life.DeploymentError, 'read-only'):
                        reader.save()
                with self.assertRaises(life.DeploymentError):
                    with life.State(path, 'target'):
                        pass
            with self.assertRaises(life.DeploymentError):
                with life.State(path, 'another-target'):
                    pass

    def test_receipt_rejects_unknown_fields_wrong_chains_and_bad_hashes(self):
        self.assertEqual(life.receipt_from_logs([{'line': 'LARK_PREPARED '+json.dumps(RECEIPT)}]), RECEIPT)
        for extra in ({'l1_chain_id':414141}, {'genesis_hash':'bad'}, {'secret':'private'}):
            with self.subTest(extra=extra), self.assertRaises(life.DeploymentError):
                life.receipt_from_logs([{'line': 'LARK_PREPARED '+json.dumps({**RECEIPT, **extra})}])
