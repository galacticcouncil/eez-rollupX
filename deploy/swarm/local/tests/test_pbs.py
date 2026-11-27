"""PBS service isolation and migration-gate regression checks."""
from pathlib import Path
import unittest
import tomllib

import yaml


ROOT = Path(__file__).resolve().parents[1]


class PbsTest(unittest.TestCase):
    def test_idle_chain_bids_start_at_the_slot_boundary(self):
        template = tomllib.loads((ROOT / "fixtures/builder.template.toml").read_text())
        self.assertEqual(template["slot_delta_to_start_bidding_ms"], -12000)

    def test_all_pbs_endpoints_are_private(self):
        for filename in ("stacks/relay.yml", "stacks/builder.yml", "stacks/boost.yml"):
            stack = yaml.safe_load((ROOT / filename).read_text())
            for service in stack["services"].values():
                self.assertNotIn("ports", service)
                self.assertEqual(service["deploy"]["update_config"]["order"], "stop-first")

    def test_database_and_redis_are_owned_by_the_pbs_stack(self):
        relay = yaml.safe_load((ROOT / "stacks/relay.yml").read_text())
        self.assertEqual(set(relay["networks"]), {"l1", "relay"})
        self.assertEqual(relay["volumes"]["postgres"]["name"], "eez-devnet-414141-postgres")
        for name in ("postgres", "redis"):
            service = relay["services"][name]
            self.assertEqual(service["networks"], ["relay"])
            self.assertIn("node.labels.platform.data == true", service["deploy"]["placement"]["constraints"])
            self.assertEqual(service["deploy"]["replicas"], 1)
        self.assertIn("/docker-entrypoint-initdb.d/10-relay.sh",
                      [c["target"] for c in relay["services"]["postgres"]["configs"]])
        self.assertIn("@postgres:5432/", (ROOT / "../components/pbs/relay-start.sh").read_text())
        for path in (ROOT / "stacks/relay.yml", ROOT / "../components/pbs/relay-start.sh", ROOT / "../components/pbs/provision-relay.sh"):
            self.assertNotIn("platform_", path.read_text())

    def test_only_postgres_mounts_its_admin_credentials(self):
        relay = yaml.safe_load((ROOT / "stacks/relay.yml").read_text())
        self.assertEqual(relay["secrets"]["postgres_password"]["name"], "eez-devnet-postgres-password")
        for name, service in relay["services"].items():
            mounted = {s["source"] for s in service.get("secrets", [])}
            self.assertEqual("postgres_password" in mounted, name == "postgres")
            self.assertNotIn("POSTGRES_DSN", service.get("environment", {}))
            self.assertNotIn("--db", service.get("command", []))
            self.assertNotIn("--secret-key", service.get("command", []))

    def test_api_waits_for_housekeeper_migrations(self):
        script = (ROOT / "../components/pbs/relay-start.sh").read_text()
        self.assertIn('if [ "$1" = api ]', script)
        self.assertIn('http://relay-housekeeper:9064/metrics', script)
        self.assertIn('"$ready" ||', script)
        self.assertLess(script.index('"$ready" ||'), script.index('exec /app/mev-boost-relay'))

    def test_builder_never_shares_canonical_writable_storage(self):
        builder = yaml.safe_load((ROOT / "stacks/builder.yml").read_text())
        self.assertEqual(builder["volumes"]["builder"]["name"], "eez-devnet-414141-builder")
        self.assertEqual(builder["volumes"]["builder_beacon"]["name"], "eez-devnet-414141-builder-beacon")
        for service in builder["services"].values():
            self.assertIn("genesis:/genesis:ro", service["volumes"])
            self.assertIn("pbs:/pbs:ro", service["volumes"])

    def test_proposer_uses_boost_without_disabling_fallback_checks(self):
        stack = yaml.safe_load((ROOT / "stacks/l1.yml").read_text())
        self.assertIn("--builder=http://mev-boost:18550", stack["services"]["beacon"]["command"])
        self.assertNotIn("--builder-fallback-disable-checks", stack["services"]["beacon"]["command"])
        self.assertIn("--builder-proposals", stack["services"]["validator"]["command"])
