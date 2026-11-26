"""Exercise lifecycle admission without a Docker daemon or live state."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[4] / "scripts/local-devnet.sh"


class LifecycleTest(unittest.TestCase):
    def run_command(self, action, state="", **extra):
        with tempfile.TemporaryDirectory(prefix="eez-lifecycle-") as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$COMMAND_LOG"
if [[ "$1 $2" == 'service inspect' ]]; then exit 0; fi
if [[ "$1 $2" == 'service ps' ]]; then printf '%s\\n' "$PREP_STATE"; exit 0; fi
''')
            docker.chmod(0o755)
            log = root / "commands"
            result = subprocess.run(["bash", str(SCRIPT), action], text=True,
                                    capture_output=True, env={**os.environ,
                                    "PATH": f"{root}:{os.environ['PATH']}",
                                    "COMMAND_LOG": str(log), "PREP_STATE": state, **extra})
            return result, log.read_text() if log.exists() else ""

    def test_existing_preparation_cannot_be_submitted_again(self):
        result, commands = self.run_command("prepare")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Preparation already exists", result.stderr)
        self.assertEqual(commands.strip(), "service inspect eez-devnet-414141-prep_prepare")

    def test_incomplete_preparation_never_starts_clients(self):
        for state in ("", "Running 2 minutes ago", "Failed 1 minute ago"):
            result, commands = self.run_command("start", state)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("stack deploy", commands)

    def test_completed_preparation_selects_intended_stack(self):
        result, commands = self.run_command("start", "Complete 2 minutes ago")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stack deploy --detach=true -c stack.yml eez-devnet", commands)

    def test_stop_targets_only_devnet_writers_and_keeps_storage(self):
        result, commands = self.run_command("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands.strip(), "service scale --detach=true eez-devnet_validator=0 "
                         "eez-devnet_beacon=0 eez-devnet_execution=0")

    def test_existing_l2_deployment_cannot_be_submitted_again(self):
        result, commands = self.run_command("l2-deploy", EEZ_DEVNET_DEPLOY_IMAGE="fixture:deploy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("L2 deployment already submitted", result.stderr)
        self.assertNotIn("volume create", commands)
        self.assertNotIn("stack deploy", commands)

    def test_l2_start_requires_completed_deployment(self):
        for state in ("", "Failed 1 minute ago", "Running 1 minute ago", "Complete 1 minute ago"):
            result, commands = self.run_command("l2-start", state,
                EEZ_DEVNET_NODE_IMAGE="fixture:node", EEZ_DEVNET_SIGNER_IMAGE="fixture:signer")
            if state.startswith("Complete"):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("stack deploy --detach=true --resolve-image never -c l2.yml eez-devnet-l2", commands)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("stack deploy", commands)

    def test_l2_stop_keeps_l1_pbs_and_all_volumes(self):
        result, commands = self.run_command("l2-stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands.strip(), "service scale --detach=true eez-devnet-l2_eez-node=0 "
                         "eez-devnet-l2_eez-beacon=0 eez-devnet-l2_eez-proof-signer=0")


class WholeNetworkTest(unittest.TestCase):
    def run_action(self, action, **extra):
        with tempfile.TemporaryDirectory(prefix="eez-network-lifecycle-") as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$COMMAND_LOG"
case "$1 $2" in
    'service inspect') test "${MISSING_SERVICE:-0}" = 0 ;;
    'service scale')
        shift 3
        for assignment in "$@"; do
            printf '%s' "${assignment##*=}" > "$STATE_DIR/${assignment%=*}"
        done ;;
    'service ps')
        name="${@: -1}"
        if [[ "$name" == "${FAULT_SERVICE:-}" ]]; then
            echo 'Running 2 minutes ago'
        elif [[ "$(cat "$STATE_DIR/$name")" == 1 ]]; then
            echo 'Running 1 second ago'
        else
            echo 'Shutdown 1 second ago'
        fi ;;
    *) exit 91 ;;
esac
''')
            docker.chmod(0o755)
            log = root / "commands"
            result = subprocess.run(["bash", str(SCRIPT), action], text=True,
                capture_output=True, timeout=15, env={**os.environ,
                "PATH": f"{root}:{os.environ['PATH']}", "COMMAND_LOG": str(log),
                "STATE_DIR": str(root), **extra})
            return result, log.read_text() if log.exists() else ""

    def test_down_waits_for_writers_then_stops_only_thirteen_owned_services(self):
        result, log = self.run_action("down")
        self.assertEqual(result.returncode, 0, result.stderr)
        scales = [line for line in log.splitlines() if line.startswith('service scale')]
        self.assertIn('eez-devnet-l2_eez-node=0', scales[0])
        self.assertIn('eez-devnet_validator=0', scales[1])
        self.assertIn('eez-devnet_execution=0', scales[-1])
        assignments = [word for line in scales for word in line.split() if word.endswith('=0')]
        self.assertEqual(len(set(assignments)), 13)
        self.assertNotIn('stack deploy', log)
        self.assertNotIn('volume', log)
        self.assertNotIn('platform_', log)

    def test_up_reuses_services_and_starts_node_after_database_and_signer(self):
        result, log = self.run_action("up")
        self.assertEqual(result.returncode, 0, result.stderr)
        scales = [line for line in log.splitlines() if line.startswith('service scale')]
        self.assertIn('eez-devnet-pbs_postgres=1', scales[0])
        self.assertIn('eez-devnet-l2_eez-proof-signer=1', scales[1])
        self.assertIn('eez-devnet-l2_eez-node=1', scales[-1])
        assignments = [word for line in scales for word in line.split() if word.endswith('=1')]
        self.assertEqual(len(set(assignments)), 13)
        self.assertNotIn('stack deploy', log)
        self.assertNotIn('volume', log)
        self.assertNotIn('prepare', '\n'.join(scales))

    def test_missing_installation_is_rejected_before_any_scaling(self):
        result, log = self.run_action("up", MISSING_SERVICE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('service scale', log)

    def test_shutdown_timeout_does_not_stop_downstream_dependencies(self):
        result, log = self.run_action("down", EEZ_DEVNET_WAIT_SECONDS="1",
                                     FAULT_SERVICE="eez-devnet-l2_eez-node")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Timed out waiting', result.stderr)
        self.assertNotIn('eez-devnet_validator=0', log)

    def test_invalid_wait_limits_never_mutate_resources(self):
        for value in ("0", "-1", "10000", "invalid"):
            result, log = self.run_action("down", EEZ_DEVNET_WAIT_SECONDS=value)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(log, "")
