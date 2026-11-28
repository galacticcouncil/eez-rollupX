"""PBS orchestration, ownership, state compatibility and credential boundaries."""
import base64
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_lifecycle import FakeApi, NODE, RECEIPT, runtime
import test_lifecycle as l1tests
import lifecycle as life
from pbs.lifecycle import PbsLifecycle, RELAY, BUILDER, load_stack, quantity

WALLET = {'address':'0x'+'34'*20, 'private_key':'0x'+'77'*32}
ENR = 'enr:'+'a'*100+'__________'  # URL-safe base64 can contain repeated underscores.
BINDINGS = dict(schema=1, execution_peer='enode://'+'11'*64+'@10.0.0.2:30303',
                beacon_peer='/dns4/beacon/tcp/9000/p2p/16Uiu2', genesis_time=1, genesis_fork='0x10000000')


class PbsApi(FakeApi):
    def __init__(self, state):
        super().__init__()
        self.state = state

    def get(self, path):
        if path.startswith('services/') and '/logs' in path:
            service = next(s for s in self.items['services'] if s['id'] == path.split('/')[1])
            stack = service['stack']
            if service['serviceName'] == RELAY+'_relay-api':
                return [{'line':'Using BLS key pubkey=0x'+'ab'*48}]
            marker = None
            if stack.endswith('-databases'):
                return [{'line':'LARK_PBS_DATABASES_READY'}]
            if stack.endswith('-bindings'):
                marker, result = 'LARK_PBS_BINDINGS', BINDINGS
            elif stack.endswith('-peer-info'):
                marker, result = 'LARK_BEACON_PEER', dict(schema=1,beacon_enr=ENR,peer_id='16Uiu2')
            elif stack.endswith('-snapshot'):
                nonce = 0 if 'funding' in stack else 2 if '-probe-' in stack else 1
                marker, result = 'LARK_PBS_SNAPSHOT', dict(schema=1, treasury=RECEIPT['treasury'],
                    nonce=hex(nonce), balance=hex(10**24), base_fee='0x7')
            elif stack.endswith('-funding'):
                marker, result = 'LARK_PBS_FUNDED', dict(schema=1,
                    hash=self.state.data['pbs']['transactions']['funding']['hash'])
            elif stack.endswith(('-canary','-canary-recovery')) or '-pbs-check-' in stack or '-pbs-probe-' in stack:
                marker = 'LARK_PBS_READY' if '-pbs-check-' in stack else 'LARK_PBS_CANARY'
                transaction = stack.split('-pbs-',1)[1] if '-pbs-probe-' in stack else 'canary'
                result = dict(schema=1, chain_id=686868,
                    hash=self.state.data['pbs']['transactions'][transaction]['hash'],
                    block_hash='0x'+'56'*32, block_number='0x100', builder_address=WALLET['address'],
                    builder_public_key='0x'+'cd'*48)
            if marker:
                return [{'line':marker+' '+json.dumps(result)}]
        return super().get(path)


class PbsTest(unittest.TestCase):
    def base(self, state, api):
        # Reuse the real L1 orchestration with deterministic crypto fixtures.
        l1tests.LifecycleTest().bootstrap(state, api)
        api.items['networks'].append({'networkName':life.PREFIX+'-prepare_default',
                                     'stack':life.PREFIX+'-prepare'})

    def cast(self, tool, *args):
        self.cast_calls.append(args)
        if args[:2] == ('wallet','new'):
            return json.dumps([WALLET])
        if args[:2] == ('wallet','address'):
            return RECEIPT['treasury']
        if args[0] == 'mktx':
            return '0x'+'ab'*100+format(int(args[args.index('--nonce')+1]),'02x')
        if args[0] == 'keccak':
            return '0x'+hashlib.sha256(args[1].encode()).hexdigest()
        raise AssertionError('unexpected cast operation')

    def bootstrap(self, state, api):
        tool = state.directory/'cast'
        tool.write_text('test cast')
        self.cast_calls = []
        operator = PbsLifecycle(api,state,runtime,30)
        with patch('pbs.lifecycle.CAST_SHA256',hashlib.sha256(tool.read_bytes()).hexdigest()), \
                patch.object(operator,'cast',side_effect=self.cast), redirect_stdout(io.StringIO()):
            result = operator.bootstrap_pbs(tool)
        return operator, result

    def test_complete_bootstrap_is_scoped_and_keeps_private_keys_out_of_configs(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory),'target') as state:
            api = PbsApi(state)
            self.base(state,api)
            before = dict(api.items['services'][0])
            operator, result = self.bootstrap(state,api)
            self.assertEqual(state.data['schema'],2)
            self.assertTrue(state.data['pbs']['qualified'])
            self.assertEqual(result['pbs']['phase'],'ready')
            self.assertEqual(len(result['services']),10)
            self.assertEqual(api.items['services'][0],before)
            self.assertEqual(state.data['pbs']['transactions']['funding']['nonce'],'0x0')
            self.assertEqual(state.data['pbs']['transactions']['canary']['nonce'],'0x1')
            beacon = state.data['stacks'][life.PREFIX]['compose']['services']['beacon']['command']
            self.assertNotIn('--disable-discovery',beacon)
            self.assertIn('--enr-address=beacon',beacon)
            self.assertIn('--disable-enr-auto-update',beacon)
            self.assertIn('--boot-nodes='+ENR,
                state.data['stacks'][BUILDER]['compose']['services']['builder-beacon']['command'])
            private = [WALLET['private_key'].removeprefix('0x'),
                       (state.directory/'relay-signing-key').read_text(),
                       (state.directory/'builder-bls-key').read_text()]
            for path,body in api.writes:
                if path == 'configs':
                    text = base64.b64decode(body['data']).decode()
                    for key in private:
                        self.assertNotIn(key,text)
            self.assertEqual((state.directory/'builder-config').stat().st_mode & 0o777,0o600)
            self.assertEqual(json.loads((state.directory/'state-before-pbs.json').read_text())['schema'],1)
            for args in self.cast_calls:
                self.assertNotIn('--private-key',args)
                self.assertNotIn('example example', ' '.join(args))
            count = len(api.writes)
            self.assertEqual(operator.bootstrap_pbs(Path('/missing'))['pbs']['phase'],'ready')
            self.assertEqual(len(api.writes),count)

    def test_whole_stack_restart_preserves_flags_keys_and_old_l1_commands_refuse(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory),'target') as state:
            api = PbsApi(state)
            self.base(state,api)
            operator,_ = self.bootstrap(state,api)
            with self.assertRaisesRegex(life.DeploymentError,'use up/down'):
                operator.scale(0)
            fingerprints = dict(state.data['fingerprints'])
            secrets_before = dict(state.data['resources']['secrets'])
            operator.all_scale(0)
            self.assertTrue(all(s['replicas']==0 for s in api.items['services'] if
                               s.get('stack') in (life.PREFIX,RELAY,BUILDER)))
            operator.all_scale(1)
            self.assertEqual(state.data['fingerprints'],fingerprints)
            self.assertEqual(state.data['resources']['secrets'],secrets_before)
            with redirect_stdout(io.StringIO()):
                self.assertEqual(operator.pbs_check()['phase'],'ready')

    def test_public_inputs_and_secret_mounts_reach_the_right_services(self):
        relay = load_stack('relay.yml',NODE)
        self.assertEqual(relay['services']['postgres']['networks'],['relay'])
        self.assertEqual(relay['services']['redis']['networks'],['relay'])
        self.assertEqual(relay['services']['relay-api']['environment']['EEZ_RELAY_DATABASE'],'eez_lark_relay')
        builder = load_stack('builder.yml',NODE,(
            ('__EXECUTION_PEER__',BINDINGS['execution_peer']),('__BEACON_PEER__',BINDINGS['beacon_peer']),
            ('__BEACON_ENR__',ENR),
            ('__TREASURY__',RECEIPT['treasury'])))
        self.assertIn('--trusted-peers='+BINDINGS['execution_peer'],builder['services']['builder']['command'])
        self.assertIn('--boot-nodes='+ENR,builder['services']['builder-beacon']['command'])
        self.assertIn('--libp2p-addresses='+BINDINGS['beacon_peer'],builder['services']['builder-beacon']['command'])
        self.assertEqual(builder['services']['builder']['entrypoint'],['/app/rbuilder'])
        self.assertNotIn('pbs:/pbs:ro',builder['services']['builder']['volumes'])
        self.assertNotIn('builder_config',json.dumps(builder['services']['mev-boost']))
        self.assertEqual(builder['secrets']['engine_jwt']['name'],life.PREFIX+'-builder-engine-jwt')
        for spec in (relay,builder):
            for role,service in spec['services'].items():
                self.assertNotIn('ports',service)
                self.assertIn('@sha256:',service['image'])
                self.assertEqual(service['deploy']['placement']['constraints'],['node.id == '+NODE])
                self.assertEqual(service['deploy']['update_config']['order'],'stop-first')
                self.assertEqual(service['logging']['options'],{'max-size':'20m','max-file':'3'})
                self.assertEqual(service['deploy']['replicas'],0)
            self.assertNotIn('eez-devnet',json.dumps(spec))

    def test_pbs_network_collision_is_rejected_before_credentials_or_state_upgrade(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory),'target') as state:
            api = PbsApi(state)
            self.base(state,api)
            before = len(api.writes)
            api.items['networks'].append({'networkName':RELAY+'_relay','stack':RELAY})
            with self.assertRaisesRegex(life.DeploymentError,'adoption'):
                self.bootstrap(state,api)
            self.assertEqual(state.data['schema'],1)
            self.assertEqual(len(api.writes),before)
            self.assertFalse((state.directory/'builder-wallet.json').exists())

    def test_quantities_and_unresolved_bindings_fail_closed(self):
        self.assertEqual(quantity('0x0'),0)
        for value in ('',None,'0xxyz','0x'+'1'*65):
            with self.subTest(value=value),self.assertRaises(life.DeploymentError):
                quantity(value)
        with self.assertRaisesRegex(life.DeploymentError,'unresolved'):
            load_stack('builder.yml',NODE)

    def test_database_replica_changes_do_not_start_relay_roles_early(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory),'target') as state:
            api = PbsApi(state)
            self.base(state,api)
            operator = PbsLifecycle(api,state,runtime,30)
            operator.initial_stack(RELAY,load_stack('relay.yml',NODE))
            operator.scale_role(RELAY,'postgres',1)
            counts = {role:service['deploy']['replicas'] for role,service in
                      api.stackfiles[RELAY]['services'].items()}
            self.assertEqual(counts,{'postgres':1,'redis':0,'relay-housekeeper':0,'relay-api':0})

    def test_canary_recovery_requires_pre_submission_failure_and_preserves_signed_bytes(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory),'target') as state:
            api = PbsApi(state)
            self.base(state,api)
            operator,_ = self.bootstrap(state,api)
            state.data['pbs']['qualified'] = False
            original = state.data['pbs']['jobs']['canary']
            service = operator.services(original)[0]['id']
            transaction = dict(state.data['pbs']['transactions']['canary'])
            get = api.get
            log = 'LARK_PBS_BUNDLE hash=already-submitted'
            def failed(path):
                if path == 'services/'+service+'/tasks':return [{'state':'failed'}]
                if path.startswith('services/'+service+'/logs?'):return [{'line':log}]
                return get(path)
            with patch.object(api,'get',side_effect=failed):
                with self.assertRaisesRegex(life.DeploymentError,'pre-submission'):
                    operator.retry_canary()
                self.assertNotIn('canary-recovery',state.data['pbs']['jobs'])
                log = 'Builder/relay/validator registration did not become ready.'
                self.assertEqual(operator.retry_canary()['pbs']['phase'],'ready')
            self.assertEqual(state.data['pbs']['transactions']['canary'],transaction)
            self.assertEqual(state.data['pbs']['jobs']['canary'],original)
            self.assertIn(original,state.data['stacks'])
            self.assertIn('canary-recovery',state.data['pbs']['jobs'])

    def test_zero_replica_count_does_not_mean_the_writer_has_exited(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory),'target') as state:
            api = PbsApi(state)
            self.base(state,api)
            operator = PbsLifecycle(api,state,runtime,30)
            operator.initial_stack(RELAY,load_stack('relay.yml',NODE))
            get = api.get
            shutting_down = True
            def tasks(path):
                if path.endswith('/tasks'):
                    return [{'state':'running' if shutting_down else 'shutdown','desiredState':'shutdown'}]
                return get(path)
            def stop(_):
                nonlocal shutting_down
                shutting_down = False
            with patch.object(api,'get',side_effect=tasks),patch('lifecycle.time.sleep',side_effect=stop) as sleep:
                operator.wait_stack(RELAY,{role:0 for role in ('postgres','redis','relay-housekeeper','relay-api')})
            sleep.assert_called_once()

    def test_probe_is_signed_once_per_start_and_noop_up_does_not_create_a_new_cycle(self):
        with tempfile.TemporaryDirectory() as directory, life.State(Path(directory),'target') as state:
            api = PbsApi(state)
            self.base(state,api)
            operator,_ = self.bootstrap(state,api)
            operator.all_scale(0)
            operator.all_scale(1)
            tool = state.directory/'cast'
            with patch('pbs.lifecycle.CAST_SHA256',hashlib.sha256(tool.read_bytes()).hexdigest()), \
                    patch.object(operator,'cast',side_effect=self.cast):
                result = operator.probe(tool)
                self.assertFalse(result['retained'])
                self.assertEqual(state.data['pbs']['transactions']['probe-1']['nonce'],'0x2')
                self.assertEqual(state.data['pbs']['transactions']['canary']['nonce'],'0x1')
                count = len(api.writes)
                self.assertTrue(operator.probe(tool)['retained'])
                self.assertEqual(len(api.writes),count)
                operator.all_scale(1)
                self.assertEqual(state.data['pbs']['start_count'],1)
                self.assertTrue(operator.probe(tool)['retained'])
