"""Physical-device R13: unavailable manual server -> reconnect -> Auto recovery.

Requires Russian ZEON UI, a connected validation VPN already set to the fault
server, the validation androidTest APK and a runtime snapshot executable. The
script drives only the public UI and stores no profile, credentials or UI dump.
"""
import argparse
import json
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--serial', required=True)
    parser.add_argument('--package', default='com.zeon.hiddify.validation')
    parser.add_argument('--fault-label', required=True, help='Exact country row text without the flag')
    parser.add_argument('--snapshot-exe', type=Path, required=True)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'com\.zeon\.hiddify(?:\.[a-z0-9_]+)*\.validation', args.package):
        parser.error('A ZEON validation package is required')
    snapshot_exe = args.snapshot_exe.resolve(strict=True)
    run_id = 'r13_' + str(time.time_ns())
    out = args.evidence_dir.resolve() / run_id
    out.mkdir(parents=True, exist_ok=False)
    result = {
        'scenario': 'unavailable manual A -> disconnect -> connect(A) -> Auto -> traffic',
        'verification_run': run_id,
        'exact_sequence_started': False,
        'passed': False,
    }

    def adb(*command):
        return subprocess.check_output(
            [args.adb, '-s', args.serial, *command],
            encoding='utf-8', errors='replace', timeout=35,
        )

    def event(name, **fields):
        row = {'utc': time.time(), 'event': name, **fields}
        with (out / 'events.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')
        # Windows acceptance hosts may expose a legacy console code page.
        print(json.dumps(row, ensure_ascii=True), flush=True)

    def nodes():
        path = '/sdcard/zeon-r13-ui.xml'
        for _ in range(4):
            adb('shell', 'rm', '-f', path)
            if 'dumped' in adb('shell', 'uiautomator', 'dump', path):
                break
            time.sleep(.5)
        else:
            raise RuntimeError('Fresh UI hierarchy unavailable')
        try:
            items = list(ET.fromstring(adb('shell', 'cat', path)).iter('node'))
        finally:
            adb('shell', 'rm', '-f', path)
        if args.package not in {node.get('package') for node in items}:
            raise RuntimeError('Validation application is not foreground')
        return items

    def label(node):
        return node.get('content-desc') or node.get('text') or ''

    def tap(text, prefix=False):
        matches = [node for node in nodes()
                   if (label(node).startswith(text) if prefix else label(node) == text)]
        if len(matches) != 1:
            raise RuntimeError('Non-unique tap target: ' + text)
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', matches[0].get('bounds')))
        adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
        event('tap', target=text)

    def wait_home(text, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(label(node) == text for node in nodes()):
                return
            time.sleep(.5)
        raise RuntimeError('UI state deadline: ' + text)

    def snapshot(name, timeout=20):
        deadline = time.monotonic() + timeout
        last_error = None
        while time.monotonic() < deadline:
            try:
                state = json.loads(subprocess.check_output(
                    [str(snapshot_exe), '28179'], encoding='utf-8',
                    stderr=subprocess.DEVNULL, timeout=5,
                ))
                event(name, core=state)
                return state
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                last_error = error
                time.sleep(.5)
        raise RuntimeError('Runtime snapshot deadline: ' + name) from last_error

    def proof_rows(probe_id):
        log = adb('logcat', '-d', '-v', 'brief', 'ZEON_VERIFY:I', '*:S')
        lines = [line for line in log.splitlines() if 'run=' + probe_id + ' ' in line]
        rows = [dict(part.split('=', 1) for part in line.split() if '=' in part)
                for line in lines]
        return lines, rows

    def probe(stage):
        probe_id = run_id + '_' + stage
        adb('shell', 'am', 'start-foreground-service', '-n', args.package +
            '.test/test.com.zeon.zeon.bg.VerificationTrafficService', '--es', 'run', probe_id)
        deadline = time.monotonic() + 30
        lines, rows = [], []
        while time.monotonic() < deadline:
            lines, rows = proof_rows(probe_id)
            if any(row.get('target') == 'matrix' and row.get('event') == 'complete' for row in rows):
                break
            time.sleep(1)
        else:
            raise RuntimeError('Traffic probe deadline: ' + stage)
        with (out / ('verification-' + stage + '.log')).open('w', encoding='utf-8') as stream:
            stream.write('\n'.join(lines) + '\n')
        events = {row.get('target'): row.get('event') for row in rows}
        event('traffic_probe', stage=stage, terminal_events=events)
        return rows

    def has(rows, target, event_name, **fields):
        return any(row.get('target') == target and row.get('event') == event_name
                   and all(row.get(key) == value for key, value in fields.items())
                   for row in rows)

    def failure_proof(rows):
        expected = {
            'zeon_204': 'http_fail',
            'apple_captive': 'real_http_fail',
            'cloudflare_speed': 'real_http_fail',
            'telegram_dc1': 'mtproto_fail',
            'telegram_dc2': 'mtproto_fail',
        }
        return {target: has(rows, target, event_name, vpn='true', interface='tun0')
                for target, event_name in expected.items()}

    def success_proof(rows):
        expected = {
            'zeon_204': ('http_pass', {'status': '204'}),
            'apple_captive': ('real_http_pass', {'status': '200'}),
            'cloudflare_speed': ('real_http_pass', {'status': '200'}),
            'telegram_dc1': ('mtproto_pass', {'response': 'resPQ'}),
            'telegram_dc2': ('mtproto_pass', {'response': 'resPQ'}),
        }
        return {target: has(rows, target, event_name, vpn='true', interface='tun0', **fields)
                for target, (event_name, fields) in expected.items()}

    try:
        adb('forward', 'tcp:28179', 'tcp:18179')
        adb('logcat', '-c')
        adb('shell', 'am', 'start', '-n', args.package + '/com.zeon.zeon.MainActivity')
        time.sleep(1)
        if any(label(node) == 'Назад' for node in nodes()):
            tap('Назад')
        wait_home('Нажмите для отключения')
        before = result['fault_precondition'] = snapshot('fault_precondition')
        if (before.get('core_status') != 'STARTED' or before.get('auto_selected') is not False
                or args.fault_label not in (before.get('selected_display') or '')
                or before.get('selected_id') != before.get('runtime_outbound_id')):
            raise RuntimeError('Unavailable manual native selection precondition failed')
        result['precondition_failure_proofs'] = failure_proof(probe('precondition'))
        if not all(result['precondition_failure_proofs'].values()):
            raise RuntimeError('Selected manual server is not a proven traffic failure')

        result['exact_sequence_started'] = True
        event('exact_sequence_begin')
        tap('Нажмите для отключения')
        wait_home('Нажмите для подключения')
        result['after_disconnect'] = {
            'ui': 'disconnected',
            'vpn_active': 'VPN:' + args.package in adb('shell', 'dumpsys', 'connectivity'),
        }
        event('after_disconnect', **result['after_disconnect'])
        if result['after_disconnect']['vpn_active']:
            raise RuntimeError('Validation VPN remained active after disconnect')
        tap('Нажмите для подключения')
        wait_home('Нажмите для отключения')
        reconnect = result['after_fault_reconnect'] = snapshot('after_fault_reconnect')
        if (reconnect.get('auto_selected') is not False
                or reconnect.get('selected_id') != before.get('selected_id')
                or reconnect.get('runtime_outbound_id') != before.get('selected_id')):
            raise RuntimeError('Fault server was not preserved across reconnect')
        result['reconnect_failure_proofs'] = failure_proof(probe('after_reconnect'))
        if not all(result['reconnect_failure_proofs'].values()):
            raise RuntimeError('Fault reconnect did not reproduce the traffic failure')

        tap('Активный сервер', prefix=True)
        tap('Страна\nАвтовыбор', prefix=True)
        event('auto_selected_by_tap')
        deadline = time.monotonic() + 45
        after = None
        while time.monotonic() < deadline:
            after = snapshot('auto_recovery_poll')
            if (after.get('auto_selected') is True
                    and after.get('runtime_outbound_present') is True
                    and after.get('runtime_outbound_id') != after.get('selected_id')
                    and after.get('runtime_outbound_id') != before.get('selected_id')):
                break
            time.sleep(1)
        else:
            raise RuntimeError('Auto did not resolve a concrete recovery leaf')
        result['after_auto'] = after
        result['recovery_success_proofs'] = success_proof(probe('after_auto'))
        result['passed'] = all(result['recovery_success_proofs'].values())
    except Exception as error:
        result['error_type'] = type(error).__name__
        result['error'] = str(error)
        raise
    finally:
        result['ended_utc'] = time.time()
        (out / 'result.json').write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8',
        )
        print('Evidence: ' + str(out), flush=True)
    if not result['passed']:
        raise RuntimeError('R13 acceptance failed; inspect evidence')


if __name__ == '__main__':
    main()
