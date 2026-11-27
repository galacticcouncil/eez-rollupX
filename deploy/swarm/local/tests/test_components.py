"""Exercise shared launchers with local and Lark inputs, without live services."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

LOCAL = Path(__file__).resolve().parents[1]
COMPONENTS = LOCAL.parent / 'components'


class ComponentsTest(unittest.TestCase):
    def run_rollup(self, role, role_file=None, extra=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            out = root / 'out'
            out.mkdir()
            (out / 'deployment-complete').touch()
            bindings = out / 'deployments.env'
            bindings.write_text('TEST_SETTING=deployment\n')
            (out / 'deployment.sha256').write_text(
                hashlib.sha256(bindings.read_bytes()).hexdigest() + f'  {bindings}\n')
            pbs = root / 'pbs'
            pbs.mkdir()
            (pbs / 'execution-peer.txt').write_text('enode://fixture')
            result_path = root / 'executed.json'
            for name in ('eez-composer', 'eez-proof-signer'):
                binary = root / name
                binary.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
Path(os.environ['RESULT']).write_text(json.dumps({
 'binary':Path(sys.argv[0]).name, 'args':sys.argv[1:],
 'setting':os.environ.get('TEST_SETTING'),
 'role_marker':os.environ.get('ROLE_MARKER')}))
''')
                binary.chmod(0o755)
            script = (COMPONENTS / 'rollup/start.sh').read_text()
            script = script.replace('/out/', str(out) + '/').replace('/pbs/', str(pbs) + '/')
            arguments = [role]
            if role_file is not None:
                if role_file == 'valid':
                    file = root / 'role.env'
                    file.write_text(f'TEST_SETTING=role-file\nROLE_MARKER={role}\n')
                    arguments.append(str(file))
                else:
                    arguments.append(role_file)
            result = subprocess.run(['sh', '-c', script, 'start.sh', *arguments, *extra],
                capture_output=True, text=True, env={**os.environ, 'TEST_SETTING':'process',
                'RESULT':str(result_path), 'PATH':f'{root}:' + os.environ['PATH']})
            return result, json.loads(result_path.read_text()) if result_path.exists() else None

    def test_role_file_preserves_precedence_and_reaches_each_runtime(self):
        for role, binary in (('node','eez-composer'), ('signer','eez-proof-signer')):
            result, executed = self.run_rollup(role, 'valid')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(executed['binary'], binary)
            self.assertEqual(executed['setting'], 'role-file')
            self.assertEqual(executed['role_marker'], role)
            self.assertTrue(any('/out/l2-genesis.json' in arg for arg in executed['args']))
        result, executed = self.run_rollup('node')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(executed['setting'], 'deployment')

    def test_bad_role_or_role_file_cannot_launch_runtime(self):
        for role, file, extra in [('other',None,()), ('node','',()),
                                  ('node','/does-not-exist',()), ('node','valid',('extra',))]:
            result, executed = self.run_rollup(role, file, extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(executed)

    def test_relay_database_validation_is_shared_by_init_and_runtime(self):
        for script in ('relay-start.sh','provision-relay.sh'):
            for value in (None, '', 'Bad', 'a-b', 'a/other', 'x'*64):
                with self.subTest(script=script,value=value):
                    env = {k:v for k,v in os.environ.items() if k != 'EEZ_RELAY_DATABASE'}
                    if value is not None:
                        env['EEZ_RELAY_DATABASE'] = value
                    result = subprocess.run(['bash',str(COMPONENTS/'pbs'/script),'housekeeper'],
                        capture_output=True, text=True, env=env)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('database', result.stderr.lower())
                    self.assertNotIn('/run/secrets', result.stderr)

    def test_local_and_lark_database_names_reach_dsn_and_provisioning(self):
        for database in ('eez_devnet_relay','eez_lark_relay','x'*63):
            with self.subTest(database=database), tempfile.TemporaryDirectory() as directory:
                root=Path(directory)
                (root/'password').write_text('fixture_password')
                (root/'genesis_validators_root.txt').write_text('0x'+'0'*64)
                (root/'config.yaml').write_text(''.join(
                    f'{fork}_FORK_VERSION: 0x00000000\n' for fork in
                    ('GENESIS','ALTAIR','BELLATRIX','CAPELLA','DENEB','ELECTRA','FULU')))
                app=root/'relay'
                app.write_text('#!/bin/sh\nprintf "%s" "$POSTGRES_DSN" > "$RESULT"\n')
                app.chmod(0o755)
                env={**os.environ,'EEZ_RELAY_DATABASE':database,'RESULT':str(root/'dsn')}
                script=(COMPONENTS/'pbs/relay-start.sh').read_text()
                script=script.replace('/run/secrets/relay-password',str(root/'password'))
                script=script.replace('/genesis/metadata',str(root))
                script=script.replace('/app/mev-boost-relay',str(app))
                result=subprocess.run(['sh','-c',script,'relay','housekeeper'],
                    capture_output=True,text=True,env=env)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual((root/'dsn').read_text(),
                    f'postgresql://{database}:fixture_password@postgres:5432/{database}?sslmode=disable')
                psql=root/'psql'
                psql.write_text('#!/bin/sh\nprintf "%s" "$EEZ_RELAY_DATABASE" > "$RESULT"\ncat > "$SQL"\n')
                psql.chmod(0o755)
                script=(COMPONENTS/'pbs/provision-relay.sh').read_text()
                script=script.replace('/run/secrets/relay-password',str(root/'password'))
                env.update(PATH=f'{root}:'+os.environ['PATH'],RESULT=str(root/'db'),SQL=str(root/'init.sql'))
                result=subprocess.run(['bash','-c',script],capture_output=True,text=True,env=env)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual((root/'db').read_text(),database)
                self.assertIn('CREATE DATABASE :"relay_database" OWNER :"relay_database";',
                              (root/'init.sql').read_text())

    def test_each_stack_config_resolves_after_relocation(self):
        for path in [*LOCAL.glob('stacks/*.yml'), *LOCAL.glob('checks/*.yml')]:
            stack = yaml.safe_load(path.read_text())
            for config in stack.get('configs',{}).values():
                if 'file' in config:
                    self.assertTrue((path.parent/config['file']).resolve().is_file(),path)
        relay = yaml.safe_load((LOCAL/'stacks/relay.yml').read_text())
        for service in ('postgres','relay-api','relay-housekeeper'):
            self.assertEqual(relay['services'][service]['environment']['EEZ_RELAY_DATABASE'],
                             'eez_devnet_relay')
        rollup = yaml.safe_load((LOCAL/'stacks/l2.yml').read_text())
        for service in ('eez-node','eez-proof-signer'):
            self.assertEqual(rollup['services'][service]['entrypoint'][-1],'/l2-fixtures.env')
