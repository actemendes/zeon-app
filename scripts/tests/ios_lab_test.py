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
import ios_lab_build as build


class ControllerTests(unittest.TestCase):
    def test_navigation_failure_is_bounded_and_never_passes(self):
        value = {'schema': 1, 'status': 'FAIL', 'steps': [], 'navigation_failure': 'server_missing'}
        self.assertEqual(lab.sanitized_device_receipt(value)['navigation_failure'], 'server_missing')
        for extra in [{'status': 'PASS'}, {'navigation_failure': 'private server tag'}]:
            with self.assertRaises(lab.Blocked):
                lab.sanitized_device_receipt(dict(value, **extra))

    def test_exit_identity_is_classified_without_retaining_addresses(self):
        value = {'schema': 1, 'status': 'FAIL', 'steps': [],
                 'failure': {'reason': 'egress_mismatch', 'target_index': 1, 'observed_exit': 'direct'}}
        self.assertEqual(lab.sanitized_device_receipt(value)['failure']['observed_exit'], 'direct')
        for reason, observed in [('egress_mismatch', '192.0.2.1'), ('network_tls', 'other')]:
            value['failure'].update(reason=reason, observed_exit=observed)
            with self.assertRaises(lab.Blocked):
                lab.sanitized_device_receipt(value)

    def test_cleanup_failure_retains_only_safe_ui_state(self):
        failure = {'expected': 'connected', 'observed': ['startingCore'], 'app_alert': False, 'system_alert': True}
        value = {'schema': 1, 'status': 'FAIL', 'steps': [{'id': 'cleanup_failed', 'time': 1}],
                 'ui_failures': [failure]}
        self.assertEqual(lab.sanitized_device_receipt(value)['ui_failures'], [failure])
        for extra in [{'status': 'PASS'}, {'ui_failures': [dict(failure, alert_text='private')]},
                      {'ui_failures': [dict(failure, observed=['private'])]},
                      {'ui_failures': [dict(failure, system_alert='private')]}]:
            with self.subTest(extra=extra), self.assertRaises(lab.Blocked):
                lab.sanitized_device_receipt(dict(value, **extra))

    def test_failed_receipt_keeps_only_bounded_diagnostics(self):
        value = {'schema': 1, 'test': 'IosLabTests/connect', 'status': 'FAIL',
                 'steps': [{'id': 'traffic_failed', 'time': 1}, {'id': 'cleanup_verified', 'time': 2}],
                 'failure': {'reason': 'egress_mismatch', 'target_index': 1}}
        result = lab.sanitized_device_receipt(value)
        self.assertNotIn('test', result)
        self.assertEqual(result['failure'], value['failure'])
        self.assertEqual(result['status'], 'FAIL')

    def test_device_receipt_rejects_private_fields_and_false_pass(self):
        base = {'schema': 1, 'test': 'IosLabTests/connect', 'status': 'FAIL', 'steps': []}
        for extra in [{'failure': {'reason': 'https://private.invalid', 'target_index': 1}},
                      {'failure': {'reason': 'network_tls', 'target_index': 1, 'body': 'private'}},
                      {'private': 'data'},
                      {'steps': [{'id': 'private-data', 'time': 1}]},
                      {'steps': [{'id': 'connected', 'time': float('nan')}]},
                      {'status': 'PASS', 'steps': [{'id': 'traffic_failed', 'time': 1}]},
                      {'status': 'PASS', 'failure': {'reason': 'network_tls', 'target_index': 1}}]:
            with self.subTest(extra=extra), self.assertRaises(lab.Blocked):
                lab.sanitized_device_receipt(dict(base, **extra))

    def test_build_publication_rejects_changed_head_or_dirty_source(self):
        for outputs, expected in [(['candidate\n', b''], True), (['other\n'], False),
                                  (['candidate\n', b' M source'], False)]:
            with patch.object(build.subprocess, 'check_output', side_effect=outputs):
                self.assertEqual(build.candidate_unchanged('candidate'), expected)

    def test_usb_probe_retains_only_packet_tunnel_presence(self):
        def response(args, timeout):
            Path(args[args.index('--json-output') + 1]).write_text(json.dumps({'result': {
                'runningProcesses': [{'executable': '/private/ZeonPacketTunnel'},
                                     {'executable': '/private/personal-app'}]}}))
        with patch.object(lab, 'command', side_effect=response):
            self.assertIs(lab.usb_probe('private-device-id'), True)

    def test_missing_completion_is_interrupted_on_disk(self):
        with tempfile.TemporaryDirectory() as work, patch.object(lab, 'command', return_value='candidate'):
            run = lab.Run('simulator', Path(work) / 'evidence')
            report = json.loads((run.path / 'report.json').read_text())
            self.assertEqual(report['status'], 'INTERRUPTED')
            self.assertFalse(report['cleanup_verified'])
            self.assertFalse(report['real_ios_vpn'])
            self.assertEqual([case['status'] for case in report['cases']], ['NOT_RUN'] * 5)

    def test_custom_evidence_names_do_not_reuse_simulator_ownership_names(self):
        with tempfile.TemporaryDirectory() as work, patch.object(lab, 'command', return_value='candidate'):
            first = lab.Run('simulator', Path(work) / 'first/run')
            second = lab.Run('simulator', Path(work) / 'second/run')
            self.assertNotEqual(first.report['run_id'], second.report['run_id'])

    def test_step_failure_preserves_start_and_timing(self):
        with tempfile.TemporaryDirectory() as work, patch.object(lab, 'command', return_value='candidate'):
            run = lab.Run('device', Path(work) / 'evidence')
            with self.assertRaises(lab.Blocked):
                run.step('usb', lambda: (_ for _ in ()).throw(lab.Blocked('lost USB')))
            report = json.loads((run.path / 'report.json').read_text())
            self.assertEqual(report['steps'][0]['status'], 'BLOCKED')
            self.assertIn('duration_seconds', report['steps'][0])
            self.assertNotEqual(report['status'], 'PASS')

    def test_pass_cannot_be_persisted_before_cleanup_and_final_completion(self):
        with tempfile.TemporaryDirectory() as work, patch.object(lab, 'command', return_value='candidate'):
            run = lab.Run('simulator', Path(work) / 'evidence')
            run.report['status'] = 'PASS'
            run.save()
            self.assertEqual(json.loads((run.path / 'report.json').read_text())['status'], 'INTERRUPTED')
            run.report['cleanup_verified'] = True
            run.save()
            self.assertEqual(json.loads((run.path / 'report.json').read_text())['status'], 'INTERRUPTED')
            run.report['ended_utc'] = lab.now()
            run.save()
            self.assertEqual(json.loads((run.path / 'report.json').read_text())['status'], 'PASS')

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

    def test_timeout_preserves_opt_in_synthetic_simulator_output(self):
        with tempfile.TemporaryDirectory() as work:
            log = Path(work) / 'simulator.log'
            with self.assertRaises(subprocess.TimeoutExpired):
                lab.command([sys.executable, '-u', '-c', 'import time; print("lab-started"); time.sleep(60)'],
                            timeout=0.2, log=log)
            self.assertIn('lab-started', log.read_text())

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
