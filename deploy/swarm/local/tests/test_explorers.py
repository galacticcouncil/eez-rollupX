"""Explorer storage, secrets, resource limits and chain separation."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class ExplorersTest(unittest.TestCase):
    def setUp(self):
        self.stack = yaml.safe_load((ROOT / "stacks/explorers.yml").read_text())

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
        self.assertIn("NOSUPERUSER NOCREATEDB NOCREATEROLE", (ROOT / "../components/explorers/postgres-init.sh").read_text())

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


class ExplorerReadinessTest(unittest.TestCase):
    def exercise(self, stats='{"total_blocks":"3"}', failure=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text('''#!/usr/bin/env bash
set -eu
url="${@: -1}"
echo "$url" >> "$REQUEST_LOG"
[[ "$url" != "$FAIL_URL" ]] || exit 22
if [[ "$url" == */api/v2/stats ]]; then printf '%s\\n' "$STATS_JSON"; fi
''')
            curl.chmod(0o755)
            result = subprocess.run(["bash", str(ROOT / "checks/check-explorers.sh")],
                text=True, capture_output=True, env={**os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}", "STATS_JSON": stats,
                    "FAIL_URL": failure, "REQUEST_LOG": str(root / "requests")})
            return result, (root / "requests").read_text().splitlines()

    def test_both_homepages_and_distinct_indexers_are_checked(self):
        result, requests = self.exercise()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [f"http://{chain}-gateway:8080{path}"
                                   for chain in ("l1", "l2") for path in ("/", "/api/v2/stats")])

    def test_an_empty_index_is_not_ready(self):
        result, _ = self.exercise('{"total_blocks":"0"}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("l1 explorer has not indexed blocks", result.stderr)

    def test_second_chain_http_failure_fails_the_whole_check(self):
        result, requests = self.exercise(failure="http://l2-gateway:8080/")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests[-1], "http://l2-gateway:8080/")

    def test_malformed_api_statistics_are_rejected(self):
        result, _ = self.exercise('{"message":"not ready"}')
        self.assertNotEqual(result.returncode, 0)
