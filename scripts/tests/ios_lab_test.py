import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'ios_lab.py'
spec = importlib.util.spec_from_file_location('ios_lab', SCRIPT)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class ControllerTests(unittest.TestCase):
    def test_missing_completion_is_interrupted_on_disk(self):
        with tempfile.TemporaryDirectory() as work, patch.object(lab, 'command', return_value='candidate'):
            run = lab.Run('simulator', Path(work) / 'evidence')
            report = json.loads((run.path / 'report.json').read_text())
            self.assertEqual(report['status'], 'INTERRUPTED')
            self.assertFalse(report['cleanup_verified'])
            self.assertFalse(report['real_ios_vpn'])

    def test_step_failure_preserves_start_and_timing(self):
        with tempfile.TemporaryDirectory() as work, patch.object(lab, 'command', return_value='candidate'):
            run = lab.Run('device', Path(work) / 'evidence')
            with self.assertRaises(lab.Blocked):
                run.step('usb', lambda: (_ for _ in ()).throw(lab.Blocked('lost USB')))
            report = json.loads((run.path / 'report.json').read_text())
            self.assertEqual(report['steps'][0]['status'], 'BLOCKED')
            self.assertIn('duration_seconds', report['steps'][0])
            self.assertNotEqual(report['status'], 'PASS')

    def test_artifact_content_or_name_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as work, patch.object(lab, 'ROOT', Path(work).resolve()):
            artifact = Path(work) / 'out/installers/ios/candidate'
            payload = artifact / 'Runner.app'
            payload.mkdir(parents=True)
            executable = payload / 'Runner'
            executable.write_bytes(b'candidate')
            (artifact / 'manifest.json').write_text(json.dumps({
                'source_dirty': False, 'kind': 'simulator', 'artifact_sha256': lab.tree_hash(payload)}))
            lab.verify_artifact(artifact)
            executable.rename(payload / 'Other')
            with self.assertRaises(lab.Blocked):
                lab.verify_artifact(artifact)

    def test_timeout_terminates_owned_child(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            lab.command([sys.executable, '-c', 'import time; time.sleep(60)'], timeout=0.05)

    def test_evidence_cannot_be_written_in_repository(self):
        with self.assertRaises(lab.Blocked):
            lab.Run('device', lab.ROOT / 'out/not-evidence')

    def test_recovery_only_deletes_recorded_simulator(self):
        with tempfile.TemporaryDirectory() as work:
            base = Path(work)
            (base / 'ownership').mkdir()
            marker = base / 'ownership/run-123.json'
            marker.write_text(json.dumps({'schema': 1, 'name': 'ZEON-run-123'}))
            devices = {'devices': {'runtime': [
                {'name': 'ZEON-run-123', 'udid': 'owned', 'state': 'Booted'},
                {'name': 'personal', 'udid': 'foreign', 'state': 'Booted'},
            ]}}
            with patch.object(lab, 'command', side_effect=[json.dumps(devices), '', '']) as calls:
                lab.recover_simulators(base)
                self.assertEqual(calls.call_args_list[-1].args[0], ['xcrun', 'simctl', 'delete', 'owned'])
                self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
