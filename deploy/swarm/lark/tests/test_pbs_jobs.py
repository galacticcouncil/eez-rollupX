"""Exercise real job scripts against fixture RPC processes, including rejection paths."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]/'pbs'
SENDER = '0x'+'12'*20
BUILDER = '0x'+'34'*20
HASH = '0x'+'22'*32
BLOCK = '0x'+'33'*32


class JobsTest(unittest.TestCase):
    def execute(self, script_name, case='good'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            public=root/'public'; public.mkdir()
            (public/'prepared').touch()
            prepared=public/'prepared.json'
            prepared.write_text(json.dumps({'genesis_hash':'0x'+'11'*32}))
            (public/'genesis.sha256').write_text(hashlib.sha256(prepared.read_bytes()).hexdigest()+'  prepared.json\n')
            input_data={'schema':1,'sender':SENDER,'builder_address':BUILDER,'hash':HASH,
                        'nonce':'0x0','value':'0x1','raw':'0x'+'ab'*100,
                        'block_hash':BLOCK,'builder_public_key':'0x'+'44'*48}
            (root/'input.json').write_text(json.dumps(input_data))
            if script_name == 'check.sh':(root/'sent').touch()
            rpc=(ROOT/'rpc.sh').read_text().replace('/public',str(public)).replace('/input.json',str(root/'input.json'))
            (root/'rpc.sh').write_text(rpc)
            tool=root/'curl'
            tool.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['TEST_ROOT']); case=os.environ['TEST_CASE']; args=sys.argv[1:]
data=json.loads((root/'input.json').read_text()); url=args[-1]
if '--data' in args:
    request=json.loads(args[args.index('--data')+1]); method=request['method']; params=request['params']
    with (root/'calls').open('a') as stream: stream.write(method+'\\n')
    if method=='eth_chainId': value='0xa7b14'
    elif method=='eth_getTransactionCount': value='0x1' if case=='nonce-conflict' else '0x0'
    elif method=='eth_blockNumber': value='0xa'
    elif method in ('eth_sendRawTransaction','eth_sendBundle'):
        (root/'sent').touch(); value=data['hash']
        if case=='accepted-timeout': sys.exit(28)
    elif method=='eth_getTransactionReceipt':
        value={'status':'0x1','transactionHash':data['hash'],'from':data['sender'],
          'to':data['builder_address'],'blockNumber':'0xc','blockHash':'0x'+'33'*32} if (root/'sent').exists() else None
    elif method=='eth_getTransactionByHash':
        value={'hash':data['hash'],'from':data['sender'],'to':data['builder_address'],
               'nonce':data['nonce'],'value':data['value']} if (root/'sent').exists() else None
        if value and case=='wrong-value': value['value']='0x2'
    elif method=='eth_getBlockByNumber':
        value={'hash':'0x'+('11' if params[0]=='0x0' else '33')*32,'number':'0xc',
               'miner':data['sender'] if case=='local-fallback' else data['builder_address']}
    elif method=='eth_getBlockByHash':
        value={'hash':'0x'+'33'*32,'number':'0xa' if case=='stale-delivery' else '0xc',
               'miner':data['sender'] if case=='local-fallback' else data['builder_address']}
    else: raise AssertionError(method)
    print(json.dumps({'result':value}))
elif '/syncing' in url: print(json.dumps({'data':{'is_syncing':False,'is_optimistic':False}}))
elif '/builder/validators' in url: print('[{}]')
elif '/proposer_payload_delivered' in url:
    print(json.dumps([{'block_hash':'0x'+'33'*32,'builder_pubkey':'0x'+'44'*48}]))
else: print('ok')
''')
            tool.chmod(0o755)
            (root/'sleep').write_text('#!/bin/sh\nexit 0\n')
            (root/'sleep').chmod(0o755)
            script=(ROOT/script_name).read_text().replace('/rpc.sh',str(root/'rpc.sh')).replace('/input.json',str(root/'input.json'))
            result=subprocess.run(['bash','-c',script],capture_output=True,text=True,timeout=10,
                env={**os.environ,'PATH':str(root)+':'+os.environ['PATH'],'TEST_ROOT':str(root),'TEST_CASE':case})
            calls=(root/'calls').read_text().splitlines() if (root/'calls').exists() else []
            return result,calls

    def test_funding_broadcasts_once_and_reconciles_an_accepted_transport_timeout(self):
        for case in ('good','accepted-timeout'):
            with self.subTest(case=case):
                result,calls=self.execute('fund.sh',case)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(calls.count('eth_sendRawTransaction'),1)
                self.assertIn('LARK_PBS_FUNDED ',result.stdout)

    def test_nonce_conflict_never_broadcasts_and_wrong_funding_value_fails(self):
        result,calls=self.execute('fund.sh','nonce-conflict')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('eth_sendRawTransaction',calls)
        result,_=self.execute('fund.sh','wrong-value')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('LARK_PBS_FUNDED ',result.stdout)

    def test_canary_is_private_and_requires_a_canonical_relay_delivery(self):
        result,calls=self.execute('canary.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(calls.count('eth_sendBundle'),1)
        self.assertNotIn('eth_sendRawTransaction',calls)
        self.assertIn('LARK_PBS_CANARY ',result.stdout)

    def test_a_local_fallback_payload_cannot_pass_as_builder_delivery(self):
        result,calls=self.execute('canary.sh','local-fallback')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('LARK_PBS_CANARY ',result.stdout)

    def test_canary_nonce_conflict_cannot_submit_a_bundle(self):
        result,calls=self.execute('canary.sh','nonce-conflict')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('eth_sendBundle',calls)
        self.assertNotIn('eth_sendRawTransaction',calls)

    def test_read_only_check_accepts_idle_history_and_rejects_wrong_coinbase(self):
        result,calls=self.execute('check.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('LARK_PBS_READY ',result.stdout)
        self.assertNotIn('eth_sendBundle',calls)
        result,calls=self.execute('check.sh','stale-delivery')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('eth_sendBundle',calls)
        result,calls=self.execute('check.sh','local-fallback')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('LARK_PBS_READY ',result.stdout)
