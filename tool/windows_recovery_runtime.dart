// Dedicated finite validation executable, never a production entrypoint.
// Build with portable=true and zeon_runtime_validation=true. The launcher
// supplies ZEON_RUNTIME_EVIDENCE_DIR and handles crash/timeout recovery.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/features/app/widget/app.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/log/model/log_level.dart' as app_log;
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/main_prod.dart' as app;
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

import 'runtime_core_snapshot.dart' show resolveRuntimeLeaf, safeId;

const port = 13434;
late Directory evidence;
ProviderContainer? container;
String phase = 'bootstrap';
int networkSequence = 0;

Future<void> record(String event, [Map<String, Object?> details = const {}]) async {
  await File('${evidence.path}/events.jsonl').writeAsString(
    '${jsonEncode({'utc': DateTime.now().toUtc().toIso8601String(), 'phase': phase, 'event': event, ...details})}\n',
    mode: FileMode.append,
    flush: true,
  );
}

Future<void> until(FutureOr<bool> Function() predicate, String reason, {int seconds = 45}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError(reason);
}

Element? findApp(Element? element) {
  if (element == null || element.widget is App) return element;
  Element? result;
  element.visitChildElements((child) {
    result ??= findApp(child);
  });
  return result;
}

Future<bool> proxyListening() async {
  try {
    final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 500));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> fetch(String url, {required bool proxy}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  client.findProxy = (_) => proxy ? 'PROXY 127.0.0.1:$port' : 'DIRECT';
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 15));
    await response.drain<void>().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw StateError('HTTPS response was not 200');
  } finally {
    client.close(force: true);
  }
}

Future<void> traffic(ServiceMode mode) async {
  await fetch('https://speed.cloudflare.com/__down?bytes=4096', proxy: true);
  await fetch('https://captive.apple.com/hotspot-detect.html', proxy: true);
  final backend = await container!.read(httpClientProvider).get<dynamic>('https://api.zeon-vps.online/health');
  if (backend.statusCode != 200) throw StateError('domain health failed');
  if (mode == ServiceMode.tun) {
    await fetch('https://captive.apple.com/hotspot-detect.html', proxy: false);
  } else if (mode == ServiceMode.systemProxy) {
    final response = await createWindowsSystemHttpTransport()!.send(
      const WindowsSystemHttpRequest(
        method: 'GET',
        url: 'https://captive.apple.com/hotspot-detect.html',
        headers: {},
        timeout: Duration(seconds: 15),
      ),
    );
    if (response.statusCode != 200) throw StateError('WinHTTP system route failed');
  }
  await record('https_and_domain_pass', {'mode': mode.name});
}

Future<void> networkSnapshot(String name) async {
  // Native utilities avoid cold PowerShell/CIM initialization in a fresh VM.
  // Keep their complete output so routing and proxy cleanup remain reviewable.
  final commands = <String, List<String>>{
    'routes_ipv4': ['route.exe', 'print', '-4'],
    'routes_ipv6': ['route.exe', 'print', '-6'],
    'interfaces': ['ipconfig.exe', '/all'],
    'tcp_endpoints': ['netstat.exe', '-ano', '-p', 'tcp'],
    for (final value in ['ProxyEnable', 'ProxyServer', 'ProxyOverride'])
      value: ['reg.exe', 'query', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', value],
  };
  final prefix = '${(++networkSequence).toString().padLeft(2, '0')}-$phase-$name';
  String quote(String value) {
    if (value.contains(RegExp(r'["%!\r\n]'))) throw StateError('Unsafe diagnostic command value');
    return '"$value"';
  }

  final script = File('${evidence.path}/$prefix-network.cmd');
  final lines = <String>['@echo off', 'setlocal DisableDelayedExpansion'];
  for (final entry in commands.entries) {
    final path = '${evidence.path}/$prefix-${entry.key}';
    lines.add('${entry.value.map(quote).join(' ')} 1>${quote('$path.stdout')} 2>${quote('$path.stderr')}');
    lines.add('echo %errorlevel% >${quote('$path.exitcode')}');
  }
  await script.writeAsString('${lines.join('\r\n')}\r\n');
  // One pipe-owning child avoids repeated process startup on a software VM.
  // The total capture deadline stays below the old seven 20-second deadlines.
  await Process.run('cmd.exe', ['/d', '/c', script.path]).timeout(const Duration(seconds: 120));
  final snapshot = <String, Object?>{};
  for (final entry in commands.entries) {
    final path = '${evidence.path}/$prefix-${entry.key}';
    final exitCode = int.parse((await File('$path.exitcode').readAsString()).trim());
    // reg.exe returns 1 for an absent optional value; retain that fact.
    if (exitCode != 0 && !(entry.value.first == 'reg.exe' && exitCode == 1)) {
      throw StateError('network evidence capture failed: ${entry.key}');
    }
    snapshot[entry.key] = {
      'exit_code': exitCode,
      'stdout': await File('$path.stdout').readAsString(encoding: systemEncoding),
      'stderr': await File('$path.stderr').readAsString(encoding: systemEncoding),
    };
  }
  await File('${evidence.path}/$prefix-network.json').writeAsString(jsonEncode(snapshot), flush: true);
  await record('network_snapshot_saved', {'snapshot': '$prefix-network.json'});
}

Future<void> connect() async {
  final configured = Platform.environment['ZEON_RUNTIME_CONNECT_TIMEOUT_SECONDS'];
  final seconds = configured == null ? 60 : int.tryParse(configured);
  if (seconds == null || seconds < 60 || seconds > 180) {
    throw StateError('Diagnostic connect deadline must be between 60 and 180 seconds');
  }
  // Software emulation can spend the normal test budget before native TUN
  // creation begins. An explicit diagnostic run may observe completion longer;
  // record that budget and elapsed time without altering application timeouts.
  final elapsed = Stopwatch()..start();
  await record('connect_requested', {'deadline_seconds': seconds});
  await container!.read(connectionNotifierProvider.notifier).toggleConnection().timeout(Duration(seconds: seconds));
  await record('connect_operation_returned', {
    'elapsed_ms': elapsed.elapsedMilliseconds,
    'exceeded_default_test_budget': elapsed.elapsedMilliseconds > 60000,
  });
  await until(() => container!.read(connectionNotifierProvider).valueOrNull is Connected, 'UI not connected');
  await record('ui_connected');
  await until(proxyListening, 'local proxy not listening');
  await record('proxy_listener_confirmed');
  final core = container!.read(zeonCoreServiceProvider).core;
  final native = await core.bgClient.coreInfoListener(Empty()).first.timeout(const Duration(seconds: 8));
  if (native.coreState.toString() != 'STARTED') throw StateError('native not STARTED');
  await record('native_connected');
  await networkSnapshot('connected');
}

Future<void> disconnect() async {
  await container!.read(connectionNotifierProvider.notifier).abortConnection().timeout(const Duration(seconds: 35));
  await until(() => container!.read(connectionNotifierProvider).valueOrNull is Disconnected, 'UI not disconnected');
  await until(() async => !await proxyListening(), 'proxy survives disconnect', seconds: 15);
  await record('disconnected_proxy_closed');
  await networkSnapshot('disconnected');
}

Future<void> modeMatrix(ServiceMode mode) async {
  phase = mode.name;
  await container!.read(ConfigOptions.serviceMode.notifier).update(mode);
  await connect();
  await traffic(mode);
  final overview = container!.listen(proxiesOverviewNotifierProvider, (_, _) {});
  try {
    final group = await container!.read(proxiesOverviewNotifierProvider.future).timeout(const Duration(seconds: 15));
    if (group == null) throw StateError('selector unavailable');
    final manual = group.items.firstWhere(
      (item) =>
          item.isVisible &&
          !const {'balance', 'urltest', 'direct', 'block', 'dns'}.contains(item.tag) &&
          !const {'selector', 'balancer', 'urltest', 'direct', 'block', 'dns'}.contains(item.type),
    );
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, manual.tag);
    await traffic(mode);
    final core = container!.read(zeonCoreServiceProvider).core;
    final actual = await core.bgClient.getSystemInfo(Empty()).timeout(const Duration(seconds: 8));
    if (actual.currentOutbound != manual.tag) throw StateError('manual runtime differs from selection');
    await record('manual_runtime_matches');
    await disconnect();
    await container!.read(proxiesOverviewNotifierProvider.future).timeout(const Duration(seconds: 10));
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, 'balance');
    await connect();
    await traffic(mode);
    final snapshotClock = Stopwatch()..start();
    final snapshot = core.bgClient.outboundsInfo(Empty()).first;
    OutboundGroupList groups;
    try {
      groups = await snapshot.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      await record('selector_snapshot_deadline_missed');
      // Preserve the failure, but observe the original request long enough to
      // distinguish slow VM execution from a stream that never produces data.
      try {
        await snapshot.timeout(const Duration(seconds: 22));
        await record('selector_snapshot_received_late', {'elapsed_ms': snapshotClock.elapsedMilliseconds});
      } catch (error) {
        await record('selector_snapshot_still_unavailable', {'error_type': error.runtimeType.toString()});
      }
      rethrow;
    }
    if (groups.items.firstWhere((item) => item.tag == group.tag).selected != 'balance') {
      throw StateError('offline Auto not applied by runtime');
    }
    final autoStats = await core.bgClient.getSystemInfo(Empty()).timeout(const Duration(seconds: 8));
    final autoLeaf = resolveRuntimeLeaf(groups, autoStats.currentOutbound);
    if (autoLeaf == null) throw StateError('Auto has no confirmed concrete native server');
    await record('offline_auto_runtime_matches', {
      'runtime_outbound_id': await safeId(autoLeaf.tag),
      'native_report_id': await safeId(autoStats.currentOutbound),
    });
    await disconnect();
  } finally {
    overview.close();
  }
}

Future<void> main() async {
  final output = Platform.environment['ZEON_RUNTIME_EVIDENCE_DIR'];
  if (!Platform.isWindows ||
      !Environment.isPortable ||
      !const bool.fromEnvironment('zeon_runtime_validation') ||
      output == null) {
    throw StateError('Dedicated Windows validation build and evidence directory required');
  }
  if (!{'ZEON-RECOVERY', 'ZEON-W11-LAB'}.contains(Platform.environment['COMPUTERNAME']?.toUpperCase())) {
    throw StateError('Runtime validation requires a dedicated ZEON recovery virtual machine');
  }
  final machine = await Process.run('reg.exe', [
    'query',
    r'HKLM\HARDWARE\DESCRIPTION\System\BIOS',
    '/v',
    'SystemManufacturer',
  ]).timeout(const Duration(seconds: 30));
  if (machine.exitCode != 0 || !(machine.stdout as String).toLowerCase().contains('qemu')) {
    throw StateError('QEMU guest identity was not confirmed');
  }
  evidence = Directory(output)..createSync(recursive: true);
  var passed = false;
  try {
    await app.main();
    await until(() => findApp(WidgetsBinding.instance.rootElement) != null, 'bootstrap timeout', seconds: 100);
    container = ProviderScope.containerOf(findApp(WidgetsBinding.instance.rootElement)!, listen: false);
    await container!.read(Preferences.introCompleted.notifier).update(true);
    final profile = await container!.read(activeProfileProvider.future);
    if (profile == null) {
      final fixturePath = Platform.environment['ZEON_RUNTIME_PROFILE_FILE'];
      if (fixturePath == null) throw StateError('Validation profile fixture required for a fresh guest');
      final repository = await container!.read(profileRepositoryProvider.future);
      final imported = await repository.addLocal(await File(fixturePath).readAsString()).run();
      if (imported.isLeft()) throw StateError('Validation profile import failed');
      await record('validation_profile_imported');
    }
    await until(() => container!.read(activeProfileProvider).valueOrNull != null, 'profile unavailable', seconds: 60);
    await container!.read(ConfigOptions.mixedPort.notifier).update(port);
    if (Platform.environment['ZEON_RUNTIME_NATIVE_DEBUG'] == '1') {
      await container!.read(ConfigOptions.logLevel.notifier).update(app_log.LogLevel.debug);
      await record('native_debug_requested');
    }
    if (await proxyListening()) throw StateError('validation proxy port already occupied');
    final requestedModes = Platform.environment['ZEON_RUNTIME_MODES'];
    final modes = requestedModes == null
        ? ServiceMode.values
        : requestedModes.split(',').map((name) => ServiceMode.values.byName(name)).toList();
    if (modes.isEmpty) throw StateError('At least one validation mode is required');
    for (final mode in modes) {
      await modeMatrix(mode);
    }
    passed = true;
  } catch (error) {
    await record('failed', {
      'error_type': error.runtimeType.toString(),
      if (error is TimeoutException) 'timeout_ms': error.duration?.inMilliseconds,
      'reason': error is StateError ? error.message : 'see redacted application logs',
    });
  } finally {
    if (container != null) {
      try {
        await container!.read(zeonCoreServiceProvider).stop(force: true).run().timeout(const Duration(seconds: 25));
      } catch (_) {
        passed = false;
      }
    }
    await File(
      '${evidence.path}/result.json',
    ).writeAsString(jsonEncode({'passed': passed, 'last_phase': phase}), flush: true);
    exit(passed ? 0 : 1);
  }
}
