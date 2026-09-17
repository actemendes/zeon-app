"""Physical-device regression: manual VPN -> off -> on -> Auto -> Telegram.

Requires Russian ZEON UI, a connected validation VPN and the androidTest APK.
Only validation packages are accepted. No chat contents or full UI dumps are saved.
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
    parser.add_argument('--manual-label', required=True, help='Exact country row text without the flag')
    parser.add_argument('--snapshot-exe', type=Path, required=True, help='Compiled tool/runtime_core_snapshot.dart')
    parser.add_argument('--evidence-dir', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'com\.zeon\.hiddify(?:\.[a-z0-9_]+)*\.validation', args.package):
        parser.error('A ZEON validation package is required')
    snapshot_exe = args.snapshot_exe.resolve(strict=True)
    run_id = 'exact_auto_' + str(time.time_ns())
    out = args.evidence_dir.resolve() / run_id
    out.mkdir(parents=True, exist_ok=False)
    result = {'scenario': 'manual VPN -> disconnect -> connect -> Auto -> Telegram',
              'verification_run': run_id, 'exact_sequence_started': False, 'passed': False}

    def adb(*command):
        return subprocess.check_output([args.adb, '-s', args.serial, *command],
                                       encoding='utf-8', errors='replace', timeout=30)

    def event(name, **fields):
        row = {'utc': time.time(), 'event': name, **fields}
        with (out / 'events.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')
        print(json.dumps(row), flush=True)

    def nodes(expected=None):
        expected = expected or args.package
        path = '/sdcard/zeon-exact-auto-ui.xml'
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
        if expected not in {node.get('package') for node in items}:
            raise RuntimeError('Expected application is not foreground')
        return items

    def label(node):
        return node.get('content-desc') or node.get('text') or ''

    def tap(text, prefix=False):
        deadline = time.monotonic() + 20
        while True:
            matches = [node for node in nodes()
                       if (label(node).startswith(text) if prefix else label(node) == text)]
            if matches or time.monotonic() >= deadline:
                break
            time.sleep(.3)
        if len(matches) > 1:
            matches = [node for node in matches if node.get('clickable') == 'true']
        if len(matches) != 1:
            raise RuntimeError('Non-unique tap target: ' + text)
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', matches[0].get('bounds')))
        adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
        event('tap', target=text)

    def wait_home(text):
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if any(label(node) == text for node in nodes()):
                return
            time.sleep(.5)
        raise RuntimeError('UI state deadline: ' + text)

    def snapshot(name):
        state = json.loads(subprocess.check_output([str(snapshot_exe), '28179'],
                                                   encoding='utf-8', timeout=15))
        event(name, core=state)
        return state

    def proof_log():
        log = adb('logcat', '-d', '-v', 'threadtime', 'ZEON_VERIFY:I', '*:S')
        # Unique run ID prevents old probes from turning an unexecuted case green.
        return '\n'.join(line for line in log.splitlines() if 'run=' + run_id + ' ' in line)

    def package_uid(package):
        match = re.search(r'^\s*appId=(\d+)\s*$', adb('shell', 'dumpsys', 'package', package), re.M)
        if not match:
            raise RuntimeError('Telegram package UID unavailable')
        return int(match.group(1))

    def uid_traffic(uid):
        # Force the in-kernel counters into NetworkStats before taking the
        # sample, then sum only this UID. No Telegram UI or chat data is read.
        adb('shell', 'dumpsys', 'netstats', '--poll', 'force')
        total_rx = total_tx = 0
        active = False
        for line in adb('shell', 'dumpsys', 'netstats', 'detail').splitlines():
            if 'ident=[' in line:
                active = re.search(r'\buid=' + str(uid) + r'\b', line) is not None
                continue
            if active:
                row = re.search(r'\brb=(\d+).*\btb=(\d+)', line)
                if row:
                    total_rx += int(row.group(1))
                    total_tx += int(row.group(2))
        return {'rx_bytes': total_rx, 'tx_bytes': total_tx}

    def proofs(log):
        expected = [('apple_captive', 'real_http_pass'), ('cloudflare_speed', 'real_http_pass'),
                    ('telegram_dc1', 'mtproto_pass'), ('telegram_dc2', 'mtproto_pass')]
        rows = [dict(part.split('=', 1) for part in line.split() if '=' in part)
                for line in log.splitlines()]
        return {target: any(all(row.get(key) == value for key, value in {
                    'run': run_id, 'target': target, 'event': event_name,
                    'vpn': 'true', 'interface': 'tun0',
                    **({'status': '200'} if event_name == 'real_http_pass' else {'response': 'resPQ'}),
                }.items()) for row in rows) for target, event_name in expected}

    try:
        adb('forward', 'tcp:28179', 'tcp:18179')
        adb('shell', 'am', 'start', '-n', args.package + '/com.zeon.zeon.MainActivity')
        foreground_deadline = time.monotonic() + 20
        while time.monotonic() < foreground_deadline:
            try:
                nodes()
                break
            except RuntimeError:
                time.sleep(.3)
        else:
            raise RuntimeError('Validation foreground preparation failed')
        # Preparation ends before the exact user sequence begins.
        tap('Главная', True)
        wait_home('Нажмите для отключения')
        tap('Активный сервер', True)
        tap('Страна\n' + args.manual_label, True)
        time.sleep(1)
        if any(label(node) == 'Назад' for node in nodes()):
            tap('Назад')
        wait_home('Нажмите для отключения')
        before = result['before'] = snapshot('manual_vpn_precondition')
        if (before.get('core_status') != 'STARTED' or before.get('auto_selected') is not False
                or not before.get('runtime_outbound_present')
                or before.get('selected_id') != before.get('runtime_outbound_id')
                or args.manual_label not in (before.get('selected_display') or '')):
            raise RuntimeError('Manual native selection precondition failed')
        if 'VPN:' + args.package not in adb('shell', 'dumpsys', 'connectivity'):
            raise RuntimeError('Validation VPN precondition missing')
        result['exact_sequence_started'] = True
        event('exact_sequence_begin')
        tap('Нажмите для отключения')
        wait_home('Нажмите для подключения')
        tap('Нажмите для подключения')
        wait_home('Нажмите для отключения')
        reconnected = result['manual_reconnected'] = snapshot('manual_reconnect_native_before_auto')
        if (reconnected.get('auto_selected') is not False
                or reconnected.get('selected_id') != before.get('selected_id')
                or reconnected.get('runtime_outbound_id') != before.get('selected_id')):
            raise RuntimeError('Manual native selection did not persist before Auto tap')
        tap('Активный сервер', True)
        tap('Страна\nАвтовыбор', True)
        event('auto_selected_by_tap')
        # Start independent traffic immediately, before observing Telegram UI.
        adb('shell', 'am', 'start-foreground-service', '-n', args.package +
            '.test/test.com.zeon.zeon.bg.VerificationTrafficService', '--es', 'run', run_id)
        proof_deadline = time.monotonic() + 45
        telegram_uid = package_uid('org.telegram.messenger')
        adb('shell', 'am', 'force-stop', 'org.telegram.messenger')
        telegram_before = uid_traffic(telegram_uid)
        adb('shell', 'am', 'start', '-n', 'org.telegram.messenger/.DefaultIcon')
        result['telegram_statuses'] = []
        for sample in range(3):
            statuses = [label(node) for node in nodes('org.telegram.messenger') if re.fullmatch(
                r'(Соединение|Подключение|Обновление|Ожидание сети|Connecting|Updating|Waiting for network)[.… ]*',
                label(node), re.I)]
            result['telegram_statuses'].append(statuses)
            event('telegram_connection_ui', sample=sample, statuses=statuses)
            if sample < 2:
                time.sleep(3)
        telegram_after = uid_traffic(telegram_uid)
        result['telegram_uid_flow'] = {
            'rx_delta': telegram_after['rx_bytes'] - telegram_before['rx_bytes'],
            'tx_delta': telegram_after['tx_bytes'] - telegram_before['tx_bytes'],
        }
        result['telegram_uid_flow']['passed'] = (
            result['telegram_uid_flow']['rx_delta'] > 0 and
            result['telegram_uid_flow']['tx_delta'] > 0)
        event('telegram_uid_flow', **result['telegram_uid_flow'])
        after = result['after_auto'] = snapshot('after_auto_telegram')
        while True:
            result['vpn_traffic_proofs'] = proofs(proof_log())
            if all(result['vpn_traffic_proofs'].values()) or time.monotonic() >= proof_deadline:
                break
            time.sleep(2)
        result['passed'] = (after.get('core_status') == 'STARTED' and after.get('auto_selected') is True
                            and after.get('runtime_outbound_present') is True
                            and after.get('runtime_outbound_id') != after.get('selected_id')
                            and all(result['vpn_traffic_proofs'].values())
                            and result['telegram_uid_flow']['passed']
                            and not any(result['telegram_statuses']))
    except Exception as error:
        result['error_type'] = type(error).__name__
        raise
    finally:
        # Persist the result even if subsequent diagnostic collection fails.
        (out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        (out / 'verification.log').write_text(proof_log(), encoding='utf-8')
        print('Evidence: ' + str(out), flush=True)
    if not result['passed']:
        raise RuntimeError('Exact Auto acceptance failed; inspect evidence')


if __name__ == '__main__':
    main()
