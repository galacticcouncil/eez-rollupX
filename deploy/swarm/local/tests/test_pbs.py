"""PBS service isolation and migration-gate regression checks."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import tomllib

import yaml


ROOT = Path(__file__).resolve().parents[1]


class PbsCanaryTest(unittest.TestCase):
    def exercise(self, duties):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = {
                "cast": '''#!/usr/bin/env bash
set -eu
echo "$1" >> "$CAST_LOG"
case "$1" in
  chain-id) echo 414141 ;;
  block-number) echo 42 ;;
  nonce) echo 1 ;;
  mktx) echo 0x1234 ;;
  keccak) echo 0x5678 ;;
  rpc) echo null ;;
  receipt) echo '{"status":"0x1"}' ;;
  *) exit 95 ;;
esac
''',
                "curl": '#!/bin/sh\nprintf "%s\\n" "$DUTIES"\n',
                "sleep": '#!/bin/sh\nexit 0\n',
                "timeout": '''#!/usr/bin/env bash
shift
[[ "$1" != bash ]] || exit 0
exec "$@"
''',
            }
            for name, body in scripts.items():
                (root / name).write_text(body)
                (root / name).chmod(0o755)
            result = subprocess.run(["bash", str(ROOT / "checks/pbs-canary.sh")],
                text=True, capture_output=True, timeout=30, env={**os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}", "DUTIES": duties,
                    "CAST_LOG": str(root / "calls")})
            return result, (root / "calls").read_text().splitlines()

    def test_empty_or_malformed_duties_never_broadcast(self):
        for duties in ('[]', '{"error":"not ready"}'):
            with self.subTest(duties=duties):
                result, calls = self.exercise(duties)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Builder did not become ready", result.stdout)
                self.assertNotIn("mktx", calls)
                self.assertNotIn("rpc", calls)

    def test_ready_duties_allow_one_bundle_and_require_receipt(self):
        result, calls = self.exercise('[{"slot":44}]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("rpc"), 1)
        self.assertIn("receipt", calls)


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
