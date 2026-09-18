#!/usr/bin/env python3
"""Bounded iOS lab controller. Run under scripts/apple/env.sh; evidence stays outside Git."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / 'apple'))
from ios_lab_build import ROOT, tree_hash

class Blocked(Exception):
    pass


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def command(args, timeout=60, env=None, log=None):
    # No shell, no inherited proxy override for the tested traffic, and no raw
    # device/profile/Flutter logs in evidence. Preserve only structured summaries.
    process = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=env, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        if log is not None:
            log.write_text(stdout + stderr)
        raise
    if log is not None:
        log.write_text(stdout + stderr)
    if process.returncode:
        raise Blocked(f'{Path(args[0]).name} exited {process.returncode}')
    return stdout


def verify_artifact(directory, development=False):
    directory = directory.resolve()
    if not directory.is_relative_to(ROOT / 'out/installers/ios'):
        raise Blocked('Artifact is outside out/installers/ios')
    manifest = json.loads((directory / 'manifest.json').read_text())
    if manifest['source_dirty'] and not development:
        raise Blocked('Dirty build cannot be accepted as immutable candidate')
    payload = directory / ('Runner.app' if manifest['kind'] in ('simulator', 'diagnostic') else 'Products')
    if tree_hash(payload) != manifest['artifact_sha256']:
        raise Blocked('Artifact hash mismatch')
    return manifest, payload


class Run:
    def __init__(self, suite, evidence):
        self.path = evidence.resolve()
        if self.path.is_relative_to(ROOT):
            raise Blocked('Evidence must be outside the repository')
        self.path.mkdir(parents=True, mode=0o700, exist_ok=False)
        self.report = {'schema': 1, 'contract': 'APPLE-TARGETED-v1', 'level': 'TARGETED',
                       'task_id': '6aad153d8f085e121ad13499', 'run_id': self.path.name + '-' + uuid.uuid4().hex[:8],
                       'started_utc': now(), 'ended_utc': None, 'suite': suite,
                       'controller_pid': os.getpid(),
                       'source_sha': command(['git', 'rev-parse', 'HEAD']).strip(),
                       'source_dirty': bool(command(['git', 'status', '--porcelain'])),
                       'evidence_kind': 'UI_LOGIC_ONLY' if suite == 'simulator' else 'DEVICE_DIAGNOSTIC',
                       'status': 'INTERRUPTED', 'classification': 'environment',
                       'cleanup_verified': False, 'artifacts': [], 'steps': [], 'cases': [],
                       'environment': {'host_arch': platform.machine(), 'host_os': platform.mac_ver()[0]},
                       'unresolved': [], 'real_ios_vpn': False}
        self.report['cases'] = [{'id': name, 'status': 'NOT_RUN'} for name in
                                (['SIM01', 'SIM02', 'SIM03', 'SIM04', 'SIM05'] if suite == 'simulator' else DEVICE_CASES)]
        self.save()

    def save(self):
        snapshot = dict(self.report)
        if snapshot['status'] == 'PASS' and (not snapshot['cleanup_verified'] or snapshot['ended_utc'] is None):
            snapshot['status'] = 'INTERRUPTED'
        if snapshot['status'] != 'PASS':
            snapshot['real_ios_vpn'] = False
        else:
            snapshot['classification'] = None
        atomic_json(self.path / 'report.json', snapshot)
        (self.path / 'report.md').write_text(
            f"# iOS lab {self.report['run_id']}\n\n"
            f"{snapshot['status']} / {self.report['evidence_kind']}\n\n"
            f"Source: {self.report['source_sha']}\n\n"
            f"Cleanup verified: {self.report['cleanup_verified']}\n\n"
            + '\n'.join(self.report['unresolved']) + '\n')

    def step(self, name, operation):
        item = {'id': name, 'started_utc': now(), 'status': 'INTERRUPTED'}
        self.report['steps'].append(item)
        self.save()
        start = time.monotonic()
        try:
            result = operation()
            item['status'] = 'PASS'
            return result
        except (Blocked, subprocess.TimeoutExpired) as error:
            item['status'] = 'BLOCKED'
            raise error
        finally:
            item['duration_seconds'] = round(time.monotonic() - start, 3)
            item['ended_utc'] = now()
            self.save()


def simulator(run, args, manifest, payload):
    if manifest['kind'] != 'simulator':
        raise Blocked('Simulator suite requires a Simulator UI/logic artifact')
    simulators = json.loads(command(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
    runtime = next((r['identifier'] for r in simulators if r['isAvailable'] and r['version'] == args.runtime), None)
    if runtime is None:
        raise Blocked('Requested Simulator runtime is unavailable')
    # Every run owns only the Simulator it creates. No erase, replacement, or
    # shutdown of a developer's existing simulator is needed.
    registry = Path.home() / 'Library/Logs/ZEON/ios-lab/ownership'
    registry.mkdir(parents=True, exist_ok=True)
    ownership = registry / (run.report['run_id'] + '.json')
    simulator_name = 'ZEON-' + run.report['run_id']
    atomic_json(ownership, {'schema': 1, 'name': simulator_name})
    device = run.step('create_simulator', lambda: command([
        'xcrun', 'simctl', 'create', simulator_name,
        'com.apple.CoreSimulator.SimDeviceType.iPhone-XR', runtime]).strip())
    run.report['environment']['simulator_os'] = args.runtime
    try:
        run.step('boot', lambda: command(['xcrun', 'simctl', 'boot', device]))
        run.step('boot_ready', lambda: command(['xcrun', 'simctl', 'bootstatus', device, '-b'], 180))
        env = dict(os.environ)
        for key in list(env):
            if key.lower() in {'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'}:
                env.pop(key)
        env['ZEON_IOS_LAB_EVIDENCE'] = str(run.path)
        for case in run.report['cases']:
            case['status'] = 'INTERRUPTED'
        try:
            run.step('ui_logic', lambda: command([
                'flutter', 'drive', '--no-pub', '-d', device,
                '--use-application-binary', str(payload),
                '--driver', 'test_driver/ios_ui_driver.dart',
                '--target', 'integration_test/ios_ui_test.dart'], 420, env, run.path / 'simulator-ui.log'))
        except Blocked:
            receipt_path = run.path / 'integration_response_data.json'
            if receipt_path.exists():
                receipt = json.loads(receipt_path.read_text())
                run.report['cases'] = [{'id': key, 'status': value} for key, value in receipt.get('cases', {}).items()]
                run.report['status'] = 'FAIL'
                run.report['classification'] = 'unknown'
            raise
        receipt = json.loads((run.path / 'integration_response_data.json').read_text())
        if (receipt.get('evidence_kind') != 'UI_LOGIC_ONLY' or receipt.get('real_ios_vpn') is not False
                or receipt.get('cases') != {key: 'PASS' for key in ['SIM01', 'SIM02', 'SIM03', 'SIM04', 'SIM05']}):
            raise Blocked('Missing or invalid Simulator completion receipt')
        run.report['cases'] = [{'id': name, 'status': status} for name, status in receipt['cases'].items()]
        run.report['status'] = 'PASS'
        run.report['classification'] = None
    finally:
        try:
            command(['xcrun', 'simctl', 'shutdown', device])
        except Blocked:
            pass
        run.step('delete_owned_simulator', lambda: command(['xcrun', 'simctl', 'delete', device]))
        ownership.unlink()
        run.report['cleanup_verified'] = True


def device_preflight(run, args):
    with tempfile.TemporaryDirectory(prefix='zeon-ios-private-') as scratch:
        data_path = Path(scratch) / 'device.json'
        command(['xcrun', 'devicectl', '--timeout', '30', '--json-output', str(data_path), 'list', 'devices'], 45)
        devices = json.loads(data_path.read_text())['result']['devices']
        selected = [d for d in devices if d['identifier'] == args.device or d['hardwareProperties'].get('udid') == args.device]
        if len(selected) != 1:
            raise Blocked('Explicit physical device is not available')
        device = selected[0]
        connection = device['connectionProperties']
        properties = device['deviceProperties']
        run.report['environment']['device'] = {
            'model': device['hardwareProperties']['productType'],
            'os': properties['osVersionNumber'], 'transport': connection.get('transportType'),
            'paired': connection.get('pairingState') == 'paired',
            'developer_mode': properties.get('developerModeStatus') == 'enabled'}
        if connection.get('transportType') != 'wired' or connection.get('pairingState') != 'paired':
            raise Blocked('Paired wired USB transport required')
        if properties.get('developerModeStatus') != 'enabled':
            raise Blocked('Developer Mode is unavailable')
    missing = [key for key in ['ZEON_LAB_RUNNER_BUNDLE_ID', 'ZEON_LAB_RUNNER_PROFILE', 'ZEON_LAB_DEVELOPMENT_TEAM']
               if not os.environ.get(key)]
    if missing:
        raise Blocked('Dedicated XCTest runner development signing is not configured; automatic provisioning is forbidden')
    if not args.fixture:
        raise Blocked('Isolated A/B fixture and two independent HTTPS echo endpoints are required')


DEVICE_CASES = {
    'connect': 'testConnectTrafficDisconnect',
    'cancel': 'testCancelObserveRetry',
    'server-ab': 'testServerAB',
    'unavailable': 'testUnavailableEndpoint',
    'close-return': 'testCloseReturn',
    'lease-expiry': 'testLeaseExpiry',
}


def sanitized_device_receipt(value):
    allowed_steps = {'lease_armed', 'connected', 'disconnected', 'direct_traffic_verified',
                     'tunnel_traffic_verified', 'cleanup_verified', 'traffic_failed', 'cleanup_failed',
                     'start_requested', 'start_tapped', 'stop_requested', 'stop_tapped', 'state_timeout', 'server_a_selected',
                     'server_picker_opened', 'server_row_found', 'server_row_tapped', 'server_row_selected', 'navigation_failed'}
    allowed_reasons = {'network_offline', 'network_dns', 'network_timeout', 'network_refused',
                       'network_cancelled', 'network_tls', 'network_other', 'http_status',
                       'origin', 'payload', 'nonce', 'marker', 'egress_mismatch',
                       'baseline_is_vpn_exit', 'baseline_disagreement'}
    if (not isinstance(value, dict) or set(value) - {'schema', 'test', 'status', 'steps', 'failure', 'ui_failures', 'navigation_failure'}
            or value.get('schema') != 1 or value.get('status') not in ('PASS', 'FAIL')
            or not isinstance(value.get('steps'), list)):
        raise Blocked('Invalid device completion receipt')
    for step in value['steps']:
        if (not isinstance(step, dict) or set(step) != {'id', 'time'} or step['id'] not in allowed_steps
                or type(step['time']) not in (int, float) or not math.isfinite(step['time'])):
            raise Blocked('Device receipt contains unexpected fields')
    if value['status'] == 'PASS' and any(step['id'] in {'traffic_failed', 'cleanup_failed', 'state_timeout', 'navigation_failed'}
                                       for step in value['steps']):
        raise Blocked('Device PASS receipt contains a failed step')
    result = {'status': value['status'], 'steps': value['steps']}
    if 'navigation_failure' in value:
        if value['status'] == 'PASS' or value['navigation_failure'] not in (
                'home_missing', 'picker_missing', 'server_missing', 'selection_timeout'):
            raise Blocked('Navigation failure must contain only a known stage')
        result['navigation_failure'] = value['navigation_failure']
    if 'failure' in value:
        failure = value['failure']
        if (value['status'] == 'PASS' or not isinstance(failure, dict)
                or set(failure) not in ({'reason', 'target_index'}, {'reason', 'target_index', 'observed_exit'})
                or failure['reason'] not in allowed_reasons
                or type(failure['target_index']) is not int or failure['target_index'] not in (1, 2)):
            raise Blocked('Device failure receipt contains unexpected fields')
        if 'observed_exit' in failure and (failure['reason'] != 'egress_mismatch'
                or failure['observed_exit'] not in ('direct', 'server_a', 'server_b', 'other')):
            raise Blocked('Device exit classification must not contain an address')
        result['failure'] = failure
    if 'ui_failures' in value:
        states = {'idle', 'disconnected', 'permissionRequired', 'startRequested', 'startingPlatform',
                  'startingCore', 'waitingTun', 'verifying', 'connected', 'stopRequested', 'stopping', 'failed'}
        failures = value['ui_failures']
        if value['status'] == 'PASS' or not isinstance(failures, list) or not 1 <= len(failures) <= 8:
            raise Blocked('Invalid UI failure receipt')
        for failure in failures:
            if (not isinstance(failure, dict) or set(failure) != {'expected', 'observed', 'app_alert', 'system_alert'}
                    or failure['expected'] not in states or not isinstance(failure['observed'], list)
                    or len(failure['observed']) > len(states)
                    or any(not isinstance(state, str) or state not in states for state in failure['observed'])
                    or type(failure['app_alert']) is not bool or type(failure['system_alert']) is not bool):
                raise Blocked('UI failure receipt contains unexpected fields')
        result['ui_failures'] = failures
    return result


def recover_simulators(base):
    markers = list(base.glob('ownership/*.json'))
    if not markers:
        return
    devices = json.loads(command(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
    for marker in markers:
        owner = json.loads(marker.read_text())
        if owner != {'schema': 1, 'name': 'ZEON-' + marker.stem}:
            raise Blocked('Invalid Simulator ownership record; refusing cleanup')
        for group in devices.values():
            for device in group:
                if device['name'] == owner['name']:
                    if device['state'] != 'Shutdown':
                        command(['xcrun', 'simctl', 'shutdown', device['udid']])
                    command(['xcrun', 'simctl', 'delete', device['udid']])
        marker.unlink()


def usb_probe(device):
    # Raw process paths can contain personal app names. Retain only this boolean.
    with tempfile.TemporaryDirectory(prefix='zeon-usb-private-') as scratch:
        result = Path(scratch) / 'processes.json'
        command(['xcrun', 'devicectl', '--timeout', '10', '--json-output', str(result),
                 'device', 'info', 'processes', '--device', device], 15)
        processes = json.loads(result.read_text())['result']['runningProcesses']
        return any(Path(process.get('executable', '')).name == 'ZeonPacketTunnel' for process in processes)


def device_run(run, args):
    if not args.artifact or not args.target_artifact:
        raise Blocked('Both runner and diagnostic target artifact manifests are required')
    runner_manifest, products = verify_artifact(args.artifact)
    target_manifest, _ = verify_artifact(args.target_artifact)
    if runner_manifest['kind'] != 'runner-device' or target_manifest['kind'] != 'diagnostic':
        raise Blocked('Device diagnostics require dedicated signed runner and diagnostic target')
    if {runner_manifest['source_sha'], target_manifest['source_sha']} != {run.report['source_sha']}:
        raise Blocked('Runner, installed target and controller must use one candidate')
    fixture = json.loads(args.fixture.read_text())
    expected_keys = {'appBundleId', 'mode', 'targets', 'directEgress', 'serverAEgress', 'serverBEgress',
                     'serverPicker', 'homeTab', 'serverA', 'serverB', 'unavailableURL'}
    if set(fixture) != expected_keys or fixture['mode'] != 'diagnostic':
        raise Blocked('Fixture must use the documented diagnostic schema without secret fields')
    if (not isinstance(fixture['targets'], list) or len(fixture['targets']) != 2
            or any(set(target) != {'url', 'marker'} for target in fixture['targets'])):
        raise Blocked('Exactly two control targets with only url/marker fields are required')
    from urllib.parse import urlparse
    for value in [target['url'] for target in fixture['targets']] + [fixture['unavailableURL']]:
        url = urlparse(value)
        if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise Blocked('Control targets must be public HTTPS URLs without credentials, query or fragment')
    run.report['fixture_sha256'] = hashlib.sha256(args.fixture.read_bytes()).hexdigest()
    run.report['artifacts'] = [dict(runner_manifest, path=str(args.artifact.resolve())),
                               dict(target_manifest, path=str(args.target_artifact.resolve()))]
    run.report['cases'] = [{'id': name, 'status': 'NOT_RUN'} for name in DEVICE_CASES]
    case = next(case for case in run.report['cases'] if case['id'] == args.case)
    templates = list(products.glob('*.xctestrun'))
    if len(templates) != 1:
        raise Blocked('Expected exactly one relocatable XCTest run specification')
    data = plistlib.loads(templates[0].read_bytes())
    target = data['IosLab']
    target['EnvironmentVariables'].update({
        'ZEON_IOS_LAB_FIXTURE': json.dumps(fixture),
        'ZEON_IOS_LAB_SOURCE_SHA': run.report['source_sha'],
        'ZEON_IOS_LAB_LEASE_SECONDS': '300' if args.case in ('cancel', 'server-ab') else '180',
    })
    target['OnlyTestIdentifiers'] = ['IosLabTests/' + DEVICE_CASES[args.case]]
    target['SystemAttachmentLifetime'] = 'deleteAlways'
    target['UITestingFailureScreenshotsEnabled'] = False
    target['UITestingScreenCapturesLifetime'] = 'deleteAlways'
    # Relocate paths structurally. The candidate and its xctestrun stay immutable.
    def relocate(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(products))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value
    heartbeats = []
    stopped = threading.Event()
    def heartbeat():
        while not stopped.is_set():
            started = time.time()
            try:
                tunnel_present = usb_probe(args.device)
                heartbeats.append({'started': started, 'ended': time.time(), 'status': 'PASS',
                                   'packet_tunnel_present': tunnel_present})
            except (Blocked, subprocess.TimeoutExpired, OSError, ValueError, KeyError):
                heartbeats.append({'started': started, 'ended': time.time(), 'status': 'INTERRUPTED'})
            stopped.wait(3)
    with tempfile.TemporaryDirectory(prefix='zeon-xctest-private-') as scratch:
        scratch = Path(scratch)
        specification = scratch / 'run.xctestrun'
        specification.write_bytes(plistlib.dumps(relocate(data)))
        result = scratch / 'result.xcresult'
        thread = threading.Thread(target=heartbeat, daemon=True)
        thread.start()
        case['status'] = 'INTERRUPTED'
        try:
            try:
                run.step('xctest', lambda: command([
                    'xcodebuild', 'test-without-building', '-xctestrun', str(specification),
                    '-destination', 'platform=iOS,id=' + args.device, '-resultBundlePath', str(result),
                    '-parallel-testing-enabled', 'NO', '-maximum-test-execution-time-allowance', '540',
                    '-test-timeouts-enabled', 'YES'], 570))
            except Blocked:
                case['status'] = 'FAIL'
                run.report['classification'] = 'unknown'
            summary = json.loads(command(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)]))
            if summary.get('skippedTests', 0) or summary.get('totalTestCount', 0) != 1:
                raise Blocked('Selected XCTest did not execute exactly once; inspect device prerequisites')
            failed = bool(summary.get('failedTests', 0) or case['status'] == 'FAIL')
            exported = scratch / 'attachments'
            command(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(exported)])
            receipts = []
            for path in exported.rglob('*'):
                if path.is_file() and path.stat().st_size < 65536:
                    try:
                        value = json.loads(path.read_bytes())
                        if isinstance(value, dict) and value.get('schema') == 1 and 'steps' in value:
                            receipts.append(value)
                    except (ValueError, UnicodeError):
                        pass
            if len(receipts) != 1:
                raise Blocked('Missing device completion and cleanup receipt')
            receipt = sanitized_device_receipt(receipts[0])
            steps = receipt['steps']
            run.report['device_steps'] = steps
            if 'ui_failures' in receipt:
                run.report['device_ui_failures'] = receipt['ui_failures']
            if 'navigation_failure' in receipt:
                run.report['device_navigation_failure'] = receipt['navigation_failure']
            run.report['cleanup_verified'] = bool(steps and steps[-1]['id'] == 'cleanup_verified')
            if failed or receipt['status'] == 'FAIL':
                run.report['status'] = case['status'] = 'FAIL'
                failure = receipt.get('failure')
                if failure:
                    run.report['device_failure'] = failure
                    connected = any(step['id'] == 'connected' for step in steps)
                    run.report['classification'] = 'unknown' if connected else 'environment'
                return
            if not {'connected', 'server_a_selected', 'direct_traffic_verified', 'tunnel_traffic_verified', 'cleanup_verified'}.issubset(
                    {step['id'] for step in steps}):
                raise Blocked('Device PASS receipt is missing required traffic or cleanup steps')
            connected = next(step['time'] for step in steps if step['id'] == 'connected')
            traffic = next(step['time'] for step in steps if step['id'] == 'tunnel_traffic_verified')
            if not any(h['status'] == 'PASS' and h['packet_tunnel_present']
                       and h['started'] >= connected and h['ended'] <= traffic for h in heartbeats):
                raise Blocked('No live USB round trip with Packet Tunnel present during verified tunnel traffic')
            if any(h['status'] != 'PASS' for h in heartbeats):
                run.report['status'] = 'INTERRUPTED'
                return
            run.report['device_steps'] = steps
            run.report['cleanup_verified'] = steps[-1]['id'] == 'cleanup_verified'
            case['status'] = 'PASS'
            run.report['status'] = 'PASS'
            run.report['real_ios_vpn'] = True
        finally:
            stopped.set()
            thread.join(timeout=20)
            if thread.is_alive():
                run.report['status'] = 'INTERRUPTED'
            run.report['usb_round_trips'] = heartbeats
            if run.report['status'] == 'PASS' and any(h['status'] != 'PASS' for h in heartbeats):
                run.report['status'] = 'INTERRUPTED'
            run.report['unresolved'].append('Ordinary-build functional acceptance and physical controller-loss drill remain NOT_RUN')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', required=True, choices=['simulator', 'device'])
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--fixture', type=Path)
    parser.add_argument('--target-artifact', type=Path)
    parser.add_argument('--case', choices=list(DEVICE_CASES), default='connect')
    parser.add_argument('--device', default='')
    parser.add_argument('--runtime', default='18.6')
    parser.add_argument('--development', action='store_true')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    base = Path.home() / 'Library/Logs/ZEON/ios-lab'
    run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    run = Run(args.suite, args.evidence or base / run_id)
    lock = None
    try:
        # One controller for the workstation prevents concurrent app/USB ownership.
        base.mkdir(parents=True, exist_ok=True)
        lock = (base / 'controller.lock').open('a')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Blocked('Another iOS lab controller owns the workstation')
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        if run.report['source_dirty'] and not args.development:
            raise Blocked('Controller acceptance requires a clean committed candidate')
        run.report['environment']['xcode'] = run.step('xcode', lambda: command(['xcodebuild', '-version'], 180)).strip()
        run.step('first_launch', lambda: command(['xcodebuild', '-checkFirstLaunchStatus']))
        run.step('recover_owned_simulators', lambda: recover_simulators(base))
        if args.suite == 'device':
            run.step('device_preflight', lambda: device_preflight(run, args))
            device_run(run, args)
        else:
            if not args.artifact:
                raise Blocked('Build with scripts/build.sh ios-test-simulator and supply --artifact')
            manifest, payload = run.step('verify_artifact', lambda: verify_artifact(args.artifact, args.development))
            if manifest['source_sha'] != run.report['source_sha']:
                raise Blocked('Controller source differs from artifact candidate')
            run.report['artifacts'].append(dict(manifest, path=str(args.artifact.resolve())))
            simulator(run, args, manifest, payload)
    except KeyboardInterrupt:
        run.report['status'] = 'INTERRUPTED'
        run.report['unresolved'].append('Controller interrupted; incomplete results are not PASS')
    except (Blocked, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
        if run.report['status'] != 'FAIL':
            run.report['status'] = 'BLOCKED'
        if isinstance(error, subprocess.TimeoutExpired):
            run.report['status'] = 'INTERRUPTED'
        # Exception text from OS/parsers can contain paths or fixture values.
        run.report['unresolved'].append(str(error) if isinstance(error, Blocked) else type(error).__name__)
        if not any(step['id'] in ('create_simulator', 'xctest') for step in run.report['steps']):
            run.report['cleanup_verified'] = True
    finally:
        if lock is not None:
            lock.close()
        run.report['ended_utc'] = now()
        if run.report['status'] == 'PASS' and not run.report['cleanup_verified']:
            run.report['status'] = 'INTERRUPTED'
        run.report['remaining_processes'] = [] if run.report['cleanup_verified'] else ['UNKNOWN']
        run.save()
        print(run.path / 'report.json')
    return 0 if run.report['status'] == 'PASS' else 2


if __name__ == '__main__':
    sys.exit(main())
