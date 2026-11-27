"""Run the actual shell wrappers with fixture generator/RPC processes."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SEED = ' '.join(['example'] * 24)


class PreparationTest(unittest.TestCase):
    def prepare(self, root, *, partial=False, wrong_chain=False):
        for role in ('public', 'validators', 'data', 'bin'):
            (root / role).mkdir()
        secret = root / 'validator-mnemonic'
        secret.write_text(SEED)
        if partial:
            (root / 'public/existing').write_text('preserve')
        tool = root / 'bin/eth2-val-tools'
        tool.write_text('''#!/usr/bin/env python3
import sys
from pathlib import Path
out=Path(next(s.split('=',1)[1] for s in sys.argv if s.startswith('--out-loc=')))
for role in ('keys','secrets'):
    (out/role).mkdir(parents=True)
    (out/role/'fixture').write_text('PRIVATESEED')
print('PRIVATESEED')
''')
        tool.chmod(0o755)
        generator = root / 'generator'
        generator.write_text('''#!/usr/bin/env python3
import json, os
from pathlib import Path
root=Path(os.environ['TEST_ROOT'])/'data'
metadata=root/'metadata'; metadata.mkdir()
genesis={'config':{'chainId':int(os.environ['TEST_CHAIN'])},
         'alloc':{'0x'+'12'*20:{'balance':'1000000000000000000000000'}}}
(metadata/'genesis.json').write_text(json.dumps(genesis))
for name in ('genesis.ssz','config.yaml','deposit_contract.txt','deposit_contract_block.txt',
             'deposit_contract_block_hash.txt','genesis_validators_root.txt','bootstrap_nodes.txt'):
    (metadata/name).write_text('public')
(metadata/'mnemonics.yaml').write_text('PRIVATESEED')
(root/'parsed').mkdir()
(root/'parsed/parsedConsensusGenesis.json').write_text(json.dumps({
 'validators':[{}]*64,'genesis_time':'1','genesis_validators_root':'0x'+'5'*64,
 'latest_execution_payload_header':{'block_hash':'0x'+'4'*64}}))
print('PRIVATESEED')
''')
        generator.chmod(0o755)
        script = (ROOT / 'prepare.sh').read_text()
        script = re.sub(r'(?<![a-zA-Z0-9_/])/(public|validators|data)\b',
                        lambda match: str(root / match[1]), script)
        script = script.replace('/run/secrets/validator-mnemonic', str(secret))
        script = script.replace('/work/entrypoint.sh', str(generator))
        return subprocess.run(['bash', '-c', script], text=True, capture_output=True,
            env={**os.environ, 'PATH':str(root/'bin')+':'+os.environ['PATH'],
                 'TEST_ROOT':str(root), 'TEST_CHAIN':'414141' if wrong_chain else '686868'})

    def test_only_public_metadata_is_published_and_logs_remain_private(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.prepare(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('LARK_PREPARED ', result.stdout)
            self.assertTrue((root/'public/prepared').is_file())
            self.assertFalse((root/'public/metadata/mnemonics.yaml').exists())
            self.assertNotIn('PRIVATESEED', result.stdout + result.stderr)
            self.assertIn('PRIVATESEED', (root/'validators/preparation/generator.log').read_text())
            self.assertEqual((root/'validators/preparation/generator.log').stat().st_mode & 0o777, 0o600)
            for path in (root/'public').rglob('*'):
                if path.is_file():
                    self.assertNotIn('PRIVATESEED', path.read_text())

    def test_partial_state_is_preserved_without_regeneration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.prepare(root, partial=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('refusing to regenerate', result.stderr)
            self.assertEqual((root/'public/existing').read_text(), 'preserve')
            self.assertFalse((root/'validators/generated').exists())

    def test_wrong_generated_chain_never_publishes_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.prepare(root, wrong_chain=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Generated L1 chain ID', result.stderr)
            self.assertFalse((root/'public/prepared').exists())
            self.assertNotIn('LARK_PREPARED ', result.stdout)

    def test_readiness_binds_execution_to_prepared_genesis(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(self.prepare(root).returncode, 0)
            curl = root/'bin/curl'
            curl.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]; url=args[-1]; root=Path(os.environ['TEST_ROOT'])
if '--data' in args:
    request=json.loads(args[args.index('--data')+1]); method=request['method']
    if method=='eth_chainId': value=hex(686868)
    elif method=='eth_blockNumber':
        path=root/'height'; value=int(path.read_text())+1 if path.exists() else 1
        path.write_text(str(value)); value=hex(value)
    elif method=='eth_getBlockByNumber':
        value={'hash':'0x'+os.environ.get('GENESIS_BYTE','4')*64,'number':'0x1'}
    else: raise AssertionError(method)
    print(json.dumps({'result':value}))
elif url.endswith('/genesis'):
    print(json.dumps({'data':{'genesis_validators_root':'0x'+'5'*64,'genesis_time':'1'}}))
else: print(json.dumps({'data':{'is_optimistic':False}}))
''')
            curl.chmod(0o755)
            sleep = root/'bin/sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o755)
            script = (ROOT/'check-l1.sh').read_text().replace('/public', str(root/'public'))
            env = {**os.environ, 'TEST_ROOT':str(root), 'PATH':str(root/'bin')+':'+os.environ['PATH']}
            good = subprocess.run(['bash','-c',script],capture_output=True,text=True,env=env)
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertIn('LARK_L1_READY chain=686868', good.stdout)
            bad = subprocess.run(['bash','-c',script],capture_output=True,text=True,
                                 env={**env,'GENESIS_BYTE':'6'})
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn('Execution genesis does not match', bad.stderr)
