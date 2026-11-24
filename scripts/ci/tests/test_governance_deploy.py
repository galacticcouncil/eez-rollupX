"""Mocked governance wrapper checks: never contacts a chain or signs a transaction."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class GovernanceDeployTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="eez-governance-port-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        for directory in ("scripts", "contracts", "bin"):
            (self.root / directory).mkdir()
        self.script = self.root / "scripts/deploy-runtime-governance.sh"
        shutil.copy2(REPO / "scripts/deploy-runtime-governance.sh", self.script)
        self.config = {
            "l1_chain_id": 31337,
            "manager": "0x" + "11" * 20,
            "eez_registry": "0x" + "22" * 20,
            "rollup_id": 1,
            "authority": "0x" + "33" * 20,
            "source_domain": "0x" + "44" * 32,
            "min_delay": 100,
            "l2_block_seconds": 2,
            "min_notice": 1000,
            "cancel_notice": 200,
            "genesis_release": {
                "runtimeVersion": 0,
                "releaseHash": "0x" + "55" * 32,
                "nodeArtifactHash": "0x" + "66" * 32,
                "guestArtifactHash": "0x" + "77" * 32,
                "programVKey": "0x" + "00" * 32,
            },
        }
        self.config_path = self.root / "config.json"
        self.genesis = self.root / "genesis.json"
        self.genesis.write_text("{}")
        self.pins = self.root / "pins.json"
        self.log = self.root / "forge.log"
        self.env = {**os.environ, "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                    "EEZ_L1_RPC_URL": "http://example.invalid", "EEZ_L2_BLOCK_TIME_MS": "2000",
                    "FORGE_LOG": str(self.log)}
        self.tool("cargo", '''
[[ "$*" == *"+1.96.0 run"* && "$*" == *"-p hydration-governance --example genesis_identity"* ]] || exit 90
echo '{"chain_id":"31338","genesis_hash":"0x8888888888888888888888888888888888888888888888888888888888888888","genesis_timestamp":1000}'
''')
        self.tool("cast", '''
case "$1" in
    chain-id) echo "${TEST_L1_CHAIN_ID:-31337}" ;;
    call)
        case "$3" in
            'EEZContract()(address)') echo 0x2222222222222222222222222222222222222222 ;;
            'rollupId()(uint64)') echo 1 ;;
            'owner()(address)') echo 0x4444444444444444444444444444444444444444 ;;
            *) exit 91 ;;
        esac ;;
    code) echo 0x6000 ;;
    keccak) echo 0x9999999999999999999999999999999999999999999999999999999999999999 ;;
    *) exit 92 ;;
esac
''')
        self.tool("forge", '''
printf '%s\\n' "$@" > "$FORGE_LOG"
[[ "${TEST_FORGE_FAIL:-0}" == 0 ]] || { echo 'fixture simulation failed'; exit 93; }
echo UPGRADE_CONTROLLER=0x4444444444444444444444444444444444444444
echo EXECUTION_SCHEDULE=0x5555555555555555555555555555555555555555
''')

    def tool(self, name, body):
        path = self.root / "bin" / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def run_script(self, *args):
        self.config_path.write_text(json.dumps(self.config))
        return subprocess.run(["bash", str(self.script), str(self.config_path), str(self.genesis),
                               str(self.pins), *args], env=self.env, text=True,
                              capture_output=True, check=False)

    def test_simulation_is_default_and_does_not_write_pins(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.pins.exists())
        self.assertIn("Simulation only", result.stdout)
        self.assertIn("DeployRuntimeGovernance", self.log.read_text())

    def test_explicit_mock_broadcast_writes_local_allowlist_and_proxy_getter_pins(self):
        result = self.run_script("--broadcast")
        self.assertEqual(result.returncode, 0, result.stderr)
        pins = json.loads(self.pins.read_text())
        self.assertEqual(pins["supported_releases"], [self.config["genesis_release"]])
        self.assertEqual(pins["l2_chain_id"], "31338")
        self.assertEqual(pins["l2_genesis_timestamp"], 1000)
        self.assertEqual(pins["controller"], "0x" + "44" * 20)
        self.assertEqual(pins["schedule_code_hash"], "0x" + "99" * 32)

    def test_wrong_chain_or_timing_never_reaches_forge(self):
        for changes in ({"TEST_L1_CHAIN_ID": "31339"}, {"EEZ_L2_BLOCK_TIME_MS": "1000"}):
            with self.subTest(changes=changes):
                saved = self.env.copy()
                self.env.update(changes)
                result = self.run_script("--broadcast")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())
                self.assertFalse(self.pins.exists())
                self.env = saved

    def test_refuses_existing_pins_without_overwriting(self):
        self.pins.write_text("preserve")
        result = self.run_script("--broadcast")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.pins.read_text(), "preserve")
        self.assertFalse(self.log.exists())

    def test_rejects_raw_key_or_rpc_override_flags(self):
        for flag in ("--private-key", "--mnemonic", "--rpc-url=http://example.invalid"):
            with self.subTest(flag=flag):
                self.assertNotEqual(self.run_script(flag).returncode, 0)
                self.assertFalse(self.log.exists())

    def test_genesis_must_be_zero_and_locally_allowlisted(self):
        self.config["supported_releases"] = []
        self.assertNotEqual(self.run_script("--broadcast").returncode, 0)
        self.assertFalse(self.log.exists())
        self.config.pop("supported_releases")
        self.config["genesis_release"]["runtimeVersion"] = 1
        self.assertNotEqual(self.run_script("--broadcast").returncode, 0)
        self.assertFalse(self.log.exists())

    def test_failed_simulation_is_visible_and_never_writes_pins(self):
        self.env["TEST_FORGE_FAIL"] = "1"
        result = self.run_script("--broadcast")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture simulation failed", result.stderr)
        self.assertFalse(self.pins.exists())
