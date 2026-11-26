"""Static checks for the server devnet's storage and network boundaries."""
import json
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class DevnetStackTest(unittest.TestCase):
    def setUp(self):
        self.stack = yaml.safe_load((ROOT / "stack.yml").read_text())
        self.prepare = yaml.safe_load((ROOT / "prepare.yml").read_text())

    def test_images_are_immutable_and_ports_private(self):
        for service in self.stack["services"].values():
            self.assertRegex(service["image"], r"@sha256:[0-9a-f]{64}$")
            self.assertNotIn("ports", service)
            self.assertEqual(service["networks"], ["l1"])

    def test_single_writers_stay_on_the_data_node(self):
        for service in self.stack["services"].values():
            deploy = service["deploy"]
            self.assertEqual(deploy["replicas"], 1)
            self.assertEqual(deploy["update_config"]["order"], "stop-first")
            self.assertEqual(deploy["rollback_config"]["order"], "stop-first")
            self.assertIn("node.labels.platform.data == true", deploy["placement"]["constraints"])

    def test_preparation_and_clients_share_fresh_chain_volumes(self):
        for role in ("genesis", "validators"):
            self.assertEqual(self.prepare["volumes"][role], self.stack["volumes"][role])
        for role, volume in self.stack["volumes"].items():
            self.assertTrue(volume["external"])
            self.assertEqual(volume["name"], f"eez-devnet-414141-{role}")
        for role in ("execution", "beacon", "validator"):
            self.assertIn("genesis:/genesis:ro", self.stack["services"][role]["volumes"])

    def test_engine_secret_only_reaches_execution_and_beacon(self):
        for role in ("execution", "beacon"):
            self.assertEqual(self.stack["services"][role]["secrets"],
                             [{"source": "engine_jwt", "target": "engine-jwt"}])
        self.assertNotIn("secrets", self.stack["services"]["validator"])
        self.assertTrue(self.stack["secrets"]["engine_jwt"]["external"])

    def test_fixture_and_health_check_match_local_manifest(self):
        manifest = json.loads((ROOT.parents[1] / "networks/local.example.json").read_text())
        self.assertEqual(manifest["l1_chain_id"], 414141)
        self.assertEqual(manifest["l2_chain_id"], 424242)
        self.assertIn(f'export CHAIN_ID={manifest["l1_chain_id"]} ', (ROOT / "prepare.sh").read_text())
        self.assertIn(hex(manifest["l1_chain_id"]), (ROOT / "check.sh").read_text())
