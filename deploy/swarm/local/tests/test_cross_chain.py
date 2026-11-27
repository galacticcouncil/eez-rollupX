"""Admission and isolation for the finite, state-changing semantic exercise."""
import os
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]


class CrossChainTest(unittest.TestCase):
    def test_fee_overlay_preserves_initial_defaults_and_matches_private_profile(self):
        base = yaml.safe_load((ROOT / "stacks/l2.yml").read_text())
        overlay = yaml.safe_load((ROOT / "stacks/l2-fees.yml").read_text())
        profile = yaml.safe_load((REPO / "testing/kurtosis/devnet-args.yaml").read_text())
        self.assertEqual(set(overlay['services']), {'eez-node'})
        env = overlay['services']['eez-node']['environment']
        expected = profile['eez']['settlement_env']
        for name, value in env.items():
            self.assertEqual(value, expected[name], name)
        for direction in ('L1_TO_L2', 'L2_TO_L1'):
            name = f'EEZ_FEES_{direction}_ENABLED'
            self.assertEqual(base['services']['eez-node']['environment'][name], 'false')
            self.assertEqual(env[name], 'true')

    def test_check_is_finite_and_cannot_write_deployment_or_git_metadata(self):
        stack = yaml.safe_load((ROOT / "checks/cross-chain.yml").read_text())
        check = stack["services"]["check"]
        self.assertEqual(check["deploy"]["restart_policy"], {"condition": "none"})
        self.assertNotIn("ports", check)
        self.assertNotIn("secrets", check)
        self.assertIn("deployment:/out:ro", check["volumes"])
        self.assertTrue(check["volumes"][-1]["read_only"])
        self.assertNotIn("node", stack["volumes"])

    def test_wrong_chain_never_funds_or_submits_a_scenario(self):
        for l1, l2 in ((100, 424242), (414141, 100)):
            with self.subTest(l1=l1, l2=l2), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                out = root / "out"
                out.mkdir()
                (out / "deployment-complete").touch()
                checked = out / "fixture"
                checked.write_bytes(b"fixture")
                (out / "deployment.sha256").write_text(
                    hashlib.sha256(b"fixture").hexdigest() + f"  {checked}\n")
                log = root / "cast.log"
                cast = root / "cast"
                cast.write_text(f'''#!/bin/sh
echo "$*" >> '{log}'
case "$*" in
  'chain-id --rpc-url http://execution:8545') echo {l1} ;;
  'chain-id --rpc-url http://eez-node:18688') echo {l2} ;;
  *) exit 77 ;;
esac
''')
                cast.chmod(0o755)
                # Only remap container filesystem paths; execute the real admission.
                script = (ROOT / "checks/cross-chain-check.sh").read_text()
                script = script.replace('/out/', str(out) + '/')
                script = script.replace('/l2-fixtures.env', str(ROOT / 'fixtures/l2-fixtures.env'))
                script = script.replace('/evidence', str(root / 'evidence'))
                result = subprocess.run(['bash', '-c', script], capture_output=True,
                                        text=True, env={**os.environ,
                                        'PATH': f'{root}:' + os.environ['PATH']})
                self.assertNotEqual(result.returncode, 0)
                calls = log.read_text()
                self.assertIn('chain-id --rpc-url http://execution:8545', calls)
                if l1 == 414141:
                    self.assertIn('chain-id --rpc-url http://eez-node:18688', calls)
                self.assertNotIn('send', calls)
                self.assertFalse((root / 'evidence').exists())

    def test_explicit_protocol_runner_does_not_require_kurtosis(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Stop at the actual pin gate, before helpers/RPC/wallet operations.
            for tool in ('bash', 'bc', 'cast', 'curl', 'find', 'flock', 'forge',
                         'git', 'jq', 'python3', 'sha256sum', 'dirname', 'awk'):
                target = root / tool
                if tool in ('bash', 'dirname', 'awk'):
                    target.symlink_to('/usr/bin/' + tool)
                else:
                    target.write_text('#!/bin/sh\nexit 0\n')
                    target.chmod(0o755)
            runner = REPO / 'testing/kurtosis/scripts/run-protocol-e2e.sh'
            for mode in ('0', '1'):
                result = subprocess.run(['/usr/bin/bash', str(runner)],
                    capture_output=True, text=True, env={**os.environ,
                    'PATH': str(root), 'EEZ_USE_LOCAL_DEPLOYMENTS': mode})
                self.assertNotEqual(result.returncode, 0)
                if mode == '0':
                    self.assertIn('kurtosis not found', result.stderr)
                else:
                    self.assertIn('not at the commit pinned', result.stderr)
                    self.assertNotIn('kurtosis not found', result.stderr)
