"""Local L2 deployment boundaries and rendered Hydration profile."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class L2Test(unittest.TestCase):
    def test_runtime_storage_is_separate_and_public_inputs_are_read_only(self):
        stack = yaml.safe_load((ROOT / "stacks/l2.yml").read_text())
        for name, service in stack["services"].items():
            self.assertNotIn("ports", service)
            self.assertEqual(service["deploy"]["replicas"], 1)
            self.assertEqual(service["deploy"]["update_config"]["order"], "stop-first")
            self.assertIn("node.labels.platform.data == true", service["deploy"]["placement"]["constraints"])
            if name == "eez-beacon":
                self.assertIn("genesis:/genesis:ro", service["volumes"])
            else:
                self.assertIn("deployment:/out:ro", service["volumes"])
                self.assertNotIn("genesis:/genesis:ro", service["volumes"])
        self.assertNotIn("secrets", stack["services"]["eez-proof-signer"])
        self.assertEqual(stack["volumes"]["node"]["name"], "eez-devnet-424242-node")
        self.assertEqual(stack["volumes"]["beacon"]["name"], "eez-devnet-424242-beacon")

    def run_deployer(self, output):
        # Run the real wrapper until deploy.sh, mocking only tools and container paths.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            (repo / "scripts").mkdir(parents=True)
            (repo / "genesis.dev.json").write_text((ROOT.parents[2] / "genesis.dev.json").read_text())
            (repo / "scripts/deploy.sh").write_text('exit 73\n')
            out = root / "out"
            out.mkdir()
            if output:
                (out / "deployment-started").mkdir()
            (root / "cast").write_text('#!/bin/sh\necho 414141\n')
            (root / "cast").chmod(0o755)
            # Only the public L1 document is copied; the signer never mounts validator data.
            (root / "l1.json").write_text('{"config":{"chainId":414141}}')
            script = (ROOT / "scripts/l2-deploy.sh").read_text().replace('/repo', str(repo)).replace('/out', str(out))
            script = script.replace('/genesis/metadata/genesis.json', str(root / 'l1.json'))
            script = script.replace('/l2-fixtures.env', str(ROOT / "fixtures/l2-fixtures.env"))
            result = subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                                    env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}"})
            base = out / "genesis.base.json"
            return result, json.loads(base.read_text()) if base.exists() else None

    def test_hydration_is_in_the_input_to_the_real_renderer(self):
        result, base = self.run_deployer(False)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(base["config"]["chainId"], 424242)
        roles = base["config"]["hydration"]
        self.assertEqual(roles["rulesVersion"], 1)
        self.assertNotEqual(roles["oracleUpdater"], roles["peplKeeper"])
        for role in ("oracleUpdater", "peplKeeper"):
            self.assertGreater(int(base["alloc"][roles[role]]["balance"], 0), 0)
        self.assertEqual(base["alloc"]["0x0000000000000000000000000000000000000800"],
                         {"nonce": "0x1", "balance": "0x0"})

    def test_partial_deployment_cannot_broadcast_again(self):
        result, base = self.run_deployer(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing a second broadcast", result.stderr)
        self.assertIsNone(base)
