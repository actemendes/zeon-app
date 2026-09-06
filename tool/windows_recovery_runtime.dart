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
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/main_prod.dart' as app;
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

const port = 13434;
late Directory evidence;
ProviderContainer? container;
String phase = 'bootstrap';

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
  final snapshot = <String, Object?>{};
  for (final entry in commands.entries) {
    final result = await Process.run(
      entry.value.first,
      entry.value.skip(1).toList(),
    ).timeout(const Duration(seconds: 20));
    // reg.exe returns 1 for an absent optional value; retain that fact.
    if (result.exitCode != 0 && !(entry.value.first == 'reg.exe' && result.exitCode == 1)) {
      throw StateError('network evidence capture failed: ${entry.key}');
    }
    snapshot[entry.key] = {'exit_code': result.exitCode, 'stdout': result.stdout, 'stderr': result.stderr};
  }
  await File('${evidence.path}/$phase-$name-network.json').writeAsString(jsonEncode(snapshot), flush: true);
}

Future<void> connect() async {
  await record('connect_requested');
  await container!.read(connectionNotifierProvider.notifier).toggleConnection().timeout(const Duration(seconds: 60));
  await record('connect_operation_returned');
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
    final groups = await core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 8));
    if (groups.items.firstWhere((item) => item.tag == group.tag).selected != 'balance') {
      throw StateError('offline Auto not applied by runtime');
    }
    await record('offline_auto_runtime_matches');
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
  if (Platform.environment['COMPUTERNAME']?.toUpperCase() != 'ZEON-RECOVERY') {
    throw StateError('Runtime validation requires the dedicated ZEON-RECOVERY virtual machine');
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
    if (await proxyListening()) throw StateError('validation proxy port already occupied');
    for (final mode in ServiceMode.values) {
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
