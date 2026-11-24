"""Network planning rejects inconsistent releases before any lifecycle action."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("network_plan", REPO / "scripts/network-plan.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NetworkPlanTest(unittest.TestCase):
    def setUp(self):
        self.network = json.loads((REPO / "deploy/networks/lark.example.json").read_text())
        self.release = {
            "schema": 2, "root_commit": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
            "protocol_commit": subprocess.check_output(
                ["git", "ls-tree", "HEAD", "eez-core-protocol"], cwd=REPO, text=True).split()[2],
            "cargo_lock_sha256": hashlib.sha256((REPO / "Cargo.lock").read_bytes()).hexdigest(),
            "binaries_sha256": "a" * 64, "platform": "linux/amd64", "profile": "release",
            "published": True, "images": {role: {
                "reference": "ghcr.io/example/" + role + "@sha256:" + "a" * 64,
                "image_id": "sha256:" + "b" * 64} for role in ("node", "signer", "deploy")}}

    def test_all_examples_plan_with_same_release(self):
        for environment in ("local", "lark", "chiado"):
            network = json.loads((REPO / f"deploy/networks/{environment}.example.json").read_text())
            result = MODULE.plan(network, self.release, REPO)
            self.assertEqual(result["release"]["images"], self.release["images"])
            self.assertEqual(result["status"], "planned-only")

    def test_persistent_network_rejects_local_images(self):
        self.release["published"] = False
        self.release["images"]["node"]["reference"] = "node:local"
        with self.assertRaisesRegex(ValueError, "published"):
            MODULE.plan(self.network, self.release, REPO)
        self.network["environment"] = "local"
        self.assertEqual(MODULE.plan(self.network, self.release, REPO)["backend"], "kurtosis")

    def test_moving_tags_rejected_for_published_release(self):
        for role in self.release["images"]:
            candidate = copy.deepcopy(self.release)
            candidate["images"][role]["reference"] = "ghcr.io/example/image:latest"
            with self.assertRaisesRegex(ValueError, "digest-pinned"):
                MODULE.plan(self.network, candidate, REPO)

    def test_revision_pin_and_lock_mismatch(self):
        for key in ("root_commit", "protocol_commit", "cargo_lock_sha256"):
            candidate = copy.deepcopy(self.release)
            candidate[key] = "0" * len(candidate[key])
            with self.assertRaises(ValueError):
                MODULE.plan(self.network, candidate, REPO)

    def test_invalid_network_inputs(self):
        for key, value in (("schema", True), ("name", "../other"), ("environment", "production"),
                           ("l1_chain_id", 10200), ("l2_chain_id", 686868),
                           ("l2_chain_id", True), ("secret", "never-echo")):
            candidate = {**self.network, key: value}
            with self.assertRaises(ValueError):
                MODULE.plan(candidate, self.release, REPO)
        for key in self.network:
            candidate = dict(self.network)
            del candidate[key]
            with self.assertRaises(ValueError):
                MODULE.plan(candidate, self.release, REPO)

    def test_chiado_requires_chiado_l1(self):
        self.network["environment"] = "chiado"
        with self.assertRaises(ValueError):
            MODULE.plan(self.network, self.release, REPO)
