"""Reset ownership and failure barriers; these tests never contact Docker."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/reset.py"
SPEC = importlib.util.spec_from_file_location("devnet_reset", SCRIPT)
reset = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reset)


def service(name, stack=None, mounts=(), networks=(), secret_ids=()):
    return {"ID": name + "-id", "Spec": {"Name": name,
        "Labels": {"com.docker.stack.namespace": stack} if stack else {},
        "TaskTemplate": {"ContainerSpec": {"Image": "fixture:" + name,
            "Mounts": [{"Type": "volume", "Source": v} for v in mounts],
            "Secrets": [{"SecretID": s} for s in secret_ids]},
            "RestartPolicy": {"Condition": "none"},
            "Networks": [{"Target": n} for n in networks]}}}


class ResetTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.services = [service(n, n.split("_")[0]) for n in reset.IMAGE_INPUTS.values()]
        self.services.append(service("eez-devnet_execution", "eez-devnet",
                                     mounts=[reset.VOLUMES[0]], networks=["l1-id"]))
        self.container_list = []
        self.configs = []
        self.node_list = [{"ID": "local", "Spec": {"Labels": {"platform.data": "true"}}}]
        self.missing_image = False

    def docker(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ("info", "--format"):
            return json.dumps({"ControlAvailable": True, "NodeID": "local"})
        kind = args[0]
        objects = {"service": self.services, "node": self.node_list,
                   "secret": [{"ID": "jwt-id", "Spec": {"Name": reset.SECRETS[0]}}],
                   "network": [{"Id": "l1-id", "Name": "eez-devnet_l1",
                                "Labels": {"com.docker.stack.namespace": "eez-devnet"}}],
                   "config": self.configs}
        if len(args) > 1 and args[1] == "ls" and kind in objects:
            return "object" if objects[kind] else ""
        if len(args) > 1 and args[1] == "inspect" and kind in objects:
            return json.dumps(objects[kind])
        if args[:2] == ("container", "ls"):
            return " ".join(c["Id"] for c in self.container_list)
        if args[:2] == ("container", "inspect"):
            return json.dumps(self.container_list)
        if args[:2] == ("stack", "config"):
            return json.dumps({"services": {"test": {"image": "fixture:image"}}})
        if args[:2] == ("image", "inspect"):
            if self.missing_image:
                raise RuntimeError("Missing image")
            return "[]"
        raise AssertionError(f"Unexpected Docker call: {args}")

    def plan(self, env=None):
        with patch.dict(reset.os.environ, env or {}, clear=True), patch.object(reset, "docker", self.docker):
            return reset.preflight()

    def test_plan_infers_images_and_excludes_other_stacks(self):
        self.services.append(service("platform_postgres", "platform", mounts=["platform_postgres_data"]))
        self.services.append(service("eez-devnet-validation-123_check", "eez-devnet-validation-123",
                                     mounts=["eez-devnet-424242-deployment"]))
        env, owned, _, _, _ = self.plan()
        self.assertEqual(env["EEZ_DEVNET_NODE_IMAGE"], "fixture:eez-devnet-l2_eez-node")
        self.assertEqual(env["EEZ_DEVNET_EXPLORER_ACCESS"], "overlay")
        names = {s["Spec"]["Name"] for s in owned}
        self.assertNotIn("platform_postgres", names)
        self.assertIn("eez-devnet-validation-123_check", names)
        self.assertNotIn("eez-devnet-validation-123", reset.VOLUMES)
        self.assertTrue(all(call[1] in ("ls", "inspect", "config", "--format") for call in self.calls))

    def test_foreign_volume_network_or_secret_user_blocks_reset(self):
        for inputs in ({"mounts": [reset.VOLUMES[0]]}, {"networks": ["l1-id"]},
                       {"secret_ids": ["jwt-id"]}):
            with self.subTest(inputs=inputs):
                self.services.append(service("other_app", "other", **inputs))
                with self.assertRaisesRegex(RuntimeError, "Foreign service"):
                    self.plan()
                self.services.pop()

    def test_foreign_config_user_is_detected(self):
        self.configs = [{"ID": "shared-config", "Spec": {"Name": "eez-devnet_script",
                         "Labels": {"com.docker.stack.namespace": "eez-devnet"}}}]
        foreign = service("other_app")
        foreign["Spec"]["TaskTemplate"]["ContainerSpec"]["Configs"] = [{"ConfigID": "shared-config"}]
        self.services.append(foreign)
        with self.assertRaisesRegex(RuntimeError, "Foreign service"):
            self.plan()

    def test_unknown_persistent_app_with_devnet_prefix_is_not_treated_as_a_probe(self):
        foreign = service("eez-devnet-monitor_app", "eez-devnet-monitor", networks=["l1-id"])
        foreign["Spec"]["TaskTemplate"]["RestartPolicy"]["Condition"] = "on-failure"
        self.services.append(foreign)
        with self.assertRaisesRegex(RuntimeError, "Foreign service"):
            self.plan()

    def test_empty_and_unknown_access_profiles_are_rejected(self):
        for value in ("", "public", "invalid"):
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "must be overlay"):
                self.plan({"EEZ_DEVNET_EXPLORER_ACCESS": value})

    def test_live_container_never_gets_force_removed_and_blocks_further_deletion(self):
        def fake_docker(*args, **kwargs):
            if args[:2] == ("container", "ls"):
                return "live-container"
            raise AssertionError(f"Destruction continued after a running container: {args}")
        with patch.object(reset, "docker", fake_docker), \
             patch.object(reset.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "running")) as command:
            with self.assertRaisesRegex(RuntimeError, "Container still holds"):
                reset.reset({}, [], [], [], ["live-container"], 1)
        self.assertNotIn("--force", command.call_args.args[0])

    def test_foreign_container_blocks_reset_even_when_no_service_references_it(self):
        self.container_list = [{"Id": "foreign", "Config": {"Labels": {}},
                               "Mounts": [{"Name": reset.VOLUMES[0]}]}]
        with self.assertRaisesRegex(RuntimeError, "Foreign or orphan container"):
            self.plan()

    def test_missing_image_and_empty_override_fail_before_any_mutation(self):
        self.missing_image = True
        with self.assertRaisesRegex(RuntimeError, "Missing image"):
            self.plan()
        with self.assertRaisesRegex(RuntimeError, "cannot be empty"):
            self.plan({"EEZ_DEVNET_NODE_IMAGE": ""})
        self.assertFalse(any("rm" in call or "scale" in call or "deploy" in call for call in self.calls))

    def test_default_command_only_previews_and_requires_explicit_yes(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(reset, "Path", return_value=Path(directory)), \
             patch.object(reset.sys, "argv", ["reset.py"]), \
             patch.object(reset, "preflight", return_value=({}, [], [], [], [])), \
             patch.object(reset, "reset") as execute, \
             patch.object(reset, "IMAGE_INPUTS", {}), \
             patch.object(reset, "print"):
            # Access is the only remaining printed environment selection.
            reset.preflight.return_value[0]["EEZ_DEVNET_EXPLORER_ACCESS"] = "overlay"
            reset.main()
        execute.assert_not_called()

    def test_multi_node_or_wrong_data_node_is_rejected(self):
        self.node_list *= 2
        with self.assertRaisesRegex(RuntimeError, "single-node"):
            self.plan()

    def test_failed_job_cannot_be_mistaken_for_completed_history(self):
        tasks = [{"Status": {"State": "complete", "ContainerStatus": {"ExitCode": 0}}},
                 {"Status": {"State": "failed", "ContainerStatus": {"ExitCode": 1}}}]
        with patch.object(reset, "docker", side_effect=["task-a task-b", json.dumps(tasks)]):
            with self.assertRaisesRegex(RuntimeError, "failed"):
                reset.wait_job("fixture_job", 1)

    def test_completed_job_requires_zero_exit(self):
        tasks = [{"Status": {"State": "complete", "ContainerStatus": {"ExitCode": 1}}}]
        with patch.object(reset, "docker", side_effect=["task", json.dumps(tasks)]), \
             patch.object(reset.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(RuntimeError, "Timed out"):
                reset.wait_job("fixture_job", 1)

    def test_reset_only_deletes_allowlisted_state_and_recreates_fees_and_explorers(self):
        calls = []
        def fake_docker(*args, **kwargs):
            calls.append((args, kwargs))
            if args[:2] == ("volume", "ls"):
                return " ".join((*reset.VOLUMES, "platform_postgres_data", "eez-devnet-evidence-123"))
            if args[:2] == ("service", "logs"):
                return "Using BLS key: 0x" + "a" * 96
            return ""
        with patch.object(reset, "docker", fake_docker), \
             patch.object(reset, "objects", return_value=[]), \
             patch.object(reset, "helper", return_value=""), \
             patch.object(reset, "wait_job"), patch.object(reset, "check"), \
             patch.object(reset, "wait_for", side_effect=lambda _, f, __: self.assertTrue(f())):
            reset.reset({}, [], [], [], [], 1)
        removed = {args[2] for args, _ in calls if args[:2] == ("volume", "rm")}
        self.assertEqual(removed, set(reset.VOLUMES))
        self.assertTrue(all("prune" not in args for args, _ in calls))
        deployments = [args for args, _ in calls if args[:2] == ("stack", "deploy")]
        self.assertTrue(any(str(reset.LOCAL / "stacks/l2-fees.yml") in args for args in deployments))
        created = [(args, kw) for args, kw in calls if args[:2] == ("secret", "create")]
        self.assertEqual({args[2] for args, _ in created}, set(reset.SECRETS))
        self.assertTrue(all(args[-1] == "-" and "input" in kw for args, kw in created))

    def test_failed_preparation_never_starts_clients_or_broadcasts(self):
        with patch.object(reset, "docker", return_value=""), \
             patch.object(reset, "objects", return_value=[]), \
             patch.object(reset, "helper") as helper, \
             patch.object(reset, "deploy") as deploy, \
             patch.object(reset, "wait_job", side_effect=RuntimeError("preparation failed")):
            with self.assertRaisesRegex(RuntimeError, "preparation failed"):
                reset.reset({}, [], [], [], [], 1)
        self.assertEqual(helper.call_args_list[0].args[0], "prepare")
        self.assertEqual(helper.call_count, 1)
        deploy.assert_not_called()

    def test_public_relay_identity_is_parsed_from_stderr(self):
        result = subprocess.CompletedProcess([], 0, "", "Using BLS key: public-key")
        with patch.object(reset.subprocess, "run", return_value=result):
            self.assertIn("public-key", reset.run("docker", "service", "logs", merge_stderr=True))


class BuilderFundingTest(unittest.TestCase):
    def exercise(self, chain, status):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "fixtures.env"
            fixture.write_text("EEZ_L1_POSTER_KEY=public-test-key\n")
            script = root / "fund.sh"
            script.write_text((SCRIPT.parent / "fund-builder.sh").read_text().replace(
                "source /l2-fixtures.env", f"source {fixture}"))
            cast = root / "cast"
            cast.write_text('''#!/usr/bin/env bash
set -eu
echo "$1" >> "$CAST_LOG"
case "$1" in
  chain-id) echo "$TEST_CHAIN" ;;
  send) echo 0x1234 ;;
  receipt) printf '{"status":"%s"}\\n' "$TEST_STATUS" ;;
  *) exit 95 ;;
esac
''')
            cast.chmod(0o755)
            result = subprocess.run(["bash", str(script)], capture_output=True, text=True,
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                     "TEST_CHAIN": chain, "TEST_STATUS": status, "CAST_LOG": str(root / "calls")})
            return result, (root / "calls").read_text().splitlines()

    def test_wrong_chain_never_funds(self):
        result, calls = self.exercise("686868", "0x1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["chain-id"])

    def test_failed_receipt_cannot_report_success(self):
        result, calls = self.exercise("414141", "0x0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["chain-id", "send", "receipt"])
        self.assertNotIn("Funded public builder", result.stdout)

    def test_successful_receipt_completes_funding(self):
        result, calls = self.exercise("414141", "0x1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("100 test ETH", result.stdout)


if __name__ == "__main__":
    unittest.main()
