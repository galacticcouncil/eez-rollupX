"""Tool setup must preserve an operator's existing directory and files."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class ToolsTest(unittest.TestCase):
    def test_existing_private_directory_and_invalid_tool_are_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            path.chmod(0o700)
            tool = path/'eth2-val-tools'
            tool.write_text('operator-owned file')
            script = Path(__file__).resolve().parents[1]/'tools.sh'
            result = subprocess.run(['bash', str(script), directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
            self.assertEqual(tool.read_text(), 'operator-owned file')
