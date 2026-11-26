"""Explorer storage, secrets, resource limits and chain separation."""
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class ExplorersTest(unittest.TestCase):
    def setUp(self):
        self.stack = yaml.safe_load((ROOT / "explorers.yml").read_text())

    def test_services_use_private_networks_and_bounded_logs(self):
        self.assertEqual(set(self.stack["networks"]), {"l1", "explorers"})
        for service in self.stack["services"].values():
            self.assertNotIn("ports", service)
            self.assertEqual(service["logging"]["options"], {"max-size": "20m", "max-file": "3"})
            self.assertEqual(service["deploy"]["replicas"], 1)
            self.assertEqual(service["deploy"]["update_config"]["order"], "stop-first")

    def test_only_database_gets_admin_secret(self):
        for name, service in self.stack["services"].items():
            secrets = {s["source"] for s in service.get("secrets", [])}
            self.assertEqual("postgres_password" in secrets, name == "postgres")
        self.assertEqual(self.stack["services"]["postgres"]["networks"], ["explorers"])
        self.assertIn("NOSUPERUSER NOCREATEDB NOCREATEROLE", (ROOT / "explorer-postgres-init.sh").read_text())

    def test_each_chain_has_its_own_runtime_credentials_and_genesis(self):
        for chain, chain_id in (("l1", 414141), ("l2", 424242)):
            service = self.stack["services"][f"{chain}-blockscout"]
            env = service["environment"]
            self.assertEqual(env["CHAIN_ID"], str(chain_id))
            self.assertEqual(env["CHAIN_SPEC_PATH"], f"/out/{chain}-genesis.json")
            self.assertNotIn("DATABASE_URL", env)
            self.assertNotIn("SECRET_KEY_BASE", env)
            self.assertEqual(service["secrets"][0]["source"], f"{chain}_password")
            self.assertIn("deployment:/out:ro", service["volumes"])
            self.assertEqual(env["DISABLE_FILE_LOGGING"], "true")
            self.assertEqual(env["INDEXER_CATCHUP_BLOCKS_CONCURRENCY"], "2")
            self.assertEqual(service["deploy"]["resources"]["limits"]["memory"], "2G")

    def test_l2_does_not_label_collected_base_fees_as_burned(self):
        env = self.stack["services"]["l2-web"]["environment"]
        self.assertEqual(env["NEXT_PUBLIC_VIEWS_BLOCK_HIDDEN_FIELDS"], '["burnt_fees"]')
        self.assertEqual(env["NEXT_PUBLIC_VIEWS_TX_HIDDEN_FIELDS"], '["burnt_fees"]')
