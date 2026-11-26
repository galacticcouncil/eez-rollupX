"""Exercise lifecycle admission without a Docker daemon or live state."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[4] / "scripts/local-devnet.sh"


class LifecycleTest(unittest.TestCase):
    def run_command(self, action, state=""):
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
                                    "COMMAND_LOG": str(log), "PREP_STATE": state})
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
