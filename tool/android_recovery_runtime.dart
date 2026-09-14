// Dedicated finite validation executable, never a production entrypoint.
// Build only through `scripts/build.ps1 -Action android-runtime`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/bootstrap.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

import 'runtime_core_snapshot.dart' show resolveRuntimeLeaf, safeId;
import 'runtime_p03_r17_validation.dart';

const _sourceSha = String.fromEnvironment('zeon_source_sha');
const _buildType = String.fromEnvironment('zeon_build_type');
const _buildUtc = String.fromEnvironment('zeon_build_utc');
const _runtimeGuard = bool.fromEnvironment('zeon_android_runtime_validation');
const _cancelObservation = Duration(seconds: 150);
const _connectTimeout = Duration(seconds: 45);
const _cleanupTimeout = Duration(seconds: 90);
const _trafficTargets = <String>[
  'https://speed.cloudflare.com/__down?bytes=4096',
  'https://captive.apple.com/hotspot-detect.html',
];

class _HarnessView extends StatelessWidget {
  const _HarnessView();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ColoredBox(
      color: Colors.black,
      child: Center(
        child: Text('ZEON Android runtime validation', style: TextStyle(color: Colors.white)),
      ),
    ),
  );
}

class _AndroidRuntimeHarness {
  _AndroidRuntimeHarness(this.container);

  final ProviderContainer container;
  final List<Map<String, Object?>> events = [];
  final List<Map<String, Object?>> traffic = [];
  late final ZeonCoreService core = container.read(zeonCoreServiceProvider);

  ConnectionNotifier get notifier => container.read(connectionNotifierProvider.notifier);

  Future<void> initialize() async {
    if (!Platform.isAndroid || !_runtimeGuard || _buildType != 'android-runtime-validation') {
      throw StateError('Dedicated Android runtime build is required');
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(_sourceSha) || _buildUtc.isEmpty) {
      throw StateError('Android runtime provenance is missing');
    }
    await container.read(connectionNotifierProvider.future).timeout(const Duration(minutes: 4));
    await container.read(Preferences.introCompleted.notifier).update(true);
    if (container.read(activeProfileProvider).valueOrNull == null) {
      throw StateError('Authorized Android profile fixture is missing');
    }
    await container.read(ConfigOptions.serviceMode.notifier).update(ServiceMode.tun);
    await _ensureStopped('initial');
    _event('harness_ready');
  }

  Future<void> run() async {
    await _runS06('app-connecting');
    await _runS06('core-starting');
    await _runS02();
    await _runP03R17();
  }

  Future<void> _runP03R17() async {
    final validation = RuntimeP03R17Validation(container);
    _event('p03_data_checks_started');
    _event('p03_data_checks_passed', await validation.runDataAndErrorChecks());

    _event('r17_disconnected_refresh_started');
    final disconnectedRefresh = await validation.refreshActiveRemoteProfile();
    final stopped =
        container.read(connectionNotifierProvider).valueOrNull is Disconnected &&
        core.currentState is CoreStopped &&
        core.authoritativeSessionSnapshot?.provesConnected != true;
    if (!stopped) throw StateError('R17 disconnected refresh changed VPN runtime ownership');
    await _verifyTraffic('r17-disconnected-refresh', expectedVpn: false);
    _event('r17_disconnected_refresh_passed', disconnectedRefresh);

    await _connectAndVerify('r17-connect');
    var group = await _selectorGroup();
    final auto = group.items.firstWhere(
      (item) => item.tag == 'balance' || item.type == 'balancer',
      orElse: () => throw StateError('Automatic proxy selector is unavailable'),
    );
    final manual = group.items.firstWhere(
      (item) =>
          item.isVisible &&
          item.tag != auto.tag &&
          !const {'selector', 'urltest', 'direct', 'block', 'dns', 'balancer'}.contains(item.type),
      orElse: () => throw StateError('No manual proxy is available for R17'),
    );
    await container.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, manual.tag);
    await _verifyNativeManual(group.tag, manual.tag);
    await _verifyTraffic('r17-manual-before-refresh', expectedVpn: true);
    final generationBefore = core.authoritativeSessionSnapshot?.generation;
    if (generationBefore == null || generationBefore <= 0) {
      throw StateError('R17 connected generation is unavailable');
    }

    _event('r17_connected_refresh_started', {'manual_outbound_id': await safeId(manual.tag)});
    final connectedRefresh = await validation.refreshActiveRemoteProfile();
    await _until(
      () {
        final snapshot = core.authoritativeSessionSnapshot;
        return container.read(connectionNotifierProvider).valueOrNull is Connected &&
            core.currentState is CoreStarted &&
            snapshot?.provesConnected == true &&
            snapshot!.generation > generationBefore;
      },
      'R17 connected refresh readiness',
      _connectTimeout,
    );
    group = await _selectorGroup();
    await _verifyNativeManual(group.tag, manual.tag);
    await _verifyTraffic('r17-connected-refresh', expectedVpn: true);
    _event('r17_connected_refresh_passed', {
      ...connectedRefresh,
      'manual_outbound_preserved': true,
      'generation_advanced': true,
    });

    group = await _selectorGroup();
    final refreshedAuto = group.items.firstWhere(
      (item) => item.tag == auto.tag,
      orElse: () => throw StateError('Auto selector disappeared after R17 refresh'),
    );
    await container.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, refreshedAuto.tag);
    await _verifyNativeSelector(group.tag, refreshedAuto.tag);
    await _verifyTraffic('task05-auto-after-profile-refresh', expectedVpn: true);
    final leaf = await _waitForConcreteLeaf(group.tag, refreshedAuto.tag);
    _event('task05_auto_after_profile_refresh_passed', {
      'selector_id': await safeId(refreshedAuto.tag),
      'runtime_outbound_id': await safeId(leaf.tag),
    });

    await _disconnectAndVerify('p03-r17');
    _event('p03_key_loss_started');
    _event('p03_key_loss_passed', await validation.runKeyLossCheckAndRestore());
  }

  Future<OutboundGroup> _selectorGroup() async {
    final group = await container.read(proxiesOverviewNotifierProvider.future).timeout(const Duration(seconds: 20));
    if (group == null) throw StateError('Proxy selector fixture is unavailable');
    return group;
  }

  Future<void> _verifyNativeManual(String groupTag, String selectedTag) async {
    final groups = await core.core.backgroundCommandClient
        .outboundsInfo(Empty())
        .first
        .timeout(const Duration(seconds: 8));
    final group = groups.items.firstWhere(
      (item) => item.tag == groupTag,
      orElse: () => throw StateError('Native selector group disappeared'),
    );
    if (group.selected != selectedTag) throw StateError('Requested manual selection was not applied');
    final system = await core.core.backgroundCommandClient.getSystemInfo(Empty()).timeout(const Duration(seconds: 8));
    if (system.currentOutbound != selectedTag) throw StateError('Manual selection differs from native runtime');
  }

  Future<void> _verifyNativeSelector(String groupTag, String selectedTag) async {
    final groups = await core.core.backgroundCommandClient
        .outboundsInfo(Empty())
        .first
        .timeout(const Duration(seconds: 8));
    final group = groups.items.firstWhere(
      (item) => item.tag == groupTag,
      orElse: () => throw StateError('Native selector group disappeared'),
    );
    if (group.selected != selectedTag) throw StateError('Requested Auto selector was not applied');
  }

  Future<OutboundInfo> _waitForConcreteLeaf(String groupTag, String selectedTag) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    do {
      try {
        final groups = await core.core.backgroundCommandClient
            .outboundsInfo(Empty())
            .first
            .timeout(const Duration(seconds: 8));
        final group = groups.items.firstWhere(
          (item) => item.tag == groupTag,
          orElse: () => throw StateError('Native selector group disappeared after Auto traffic'),
        );
        if (group.selected != selectedTag) throw StateError('Native selector changed during Auto traffic');
        final system = await core.core.backgroundCommandClient
            .getSystemInfo(Empty())
            .timeout(const Duration(seconds: 8));
        final leaf = resolveRuntimeLeaf(groups, system.currentOutbound);
        if (leaf != null) return leaf;
      } on GrpcError {
        if (container.read(connectionNotifierProvider).valueOrNull is! Connected || core.currentState is! CoreStarted) {
          rethrow;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } while (DateTime.now().isBefore(deadline));
    throw TimeoutException('Auto concrete native outbound after traffic', const Duration(seconds: 30));
  }

  Future<void> _runS06(String phase) async {
    _event('s06_started', {'phase': phase});
    final operation = notifier.toggleConnection();
    await _until(
      () {
        final app = container.read(connectionNotifierProvider).valueOrNull;
        return phase == 'app-connecting' ? app is Connecting : app is Connecting && core.currentState is CoreStarting;
      },
      'observable $phase',
      _connectTimeout,
    );
    _event('cancel_phase_observed', {'phase': phase, ..._state()});
    await notifier.abortConnection().timeout(_cleanupTimeout);
    try {
      await operation.timeout(_cleanupTimeout);
    } catch (error) {
      _event('superseded_connect_error', {'phase': phase, 'error_type': error.runtimeType.toString()});
    }
    await _ensureStopped('s06-$phase-cancel');
    final deadline = DateTime.now().add(_cancelObservation);
    while (DateTime.now().isBefore(deadline)) {
      final app = container.read(connectionNotifierProvider).valueOrNull;
      final snapshot = core.authoritativeSessionSnapshot;
      if (app is Connecting ||
          app is Connected ||
          core.currentState is CoreStarting ||
          core.currentState is CoreStarted ||
          snapshot?.provesConnected == true) {
        throw StateError('Late activation after $phase cancellation');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    _event('no_late_activation', {'phase': phase, 'observed_seconds': _cancelObservation.inSeconds});
    await _connectAndVerify('s06-$phase-retry');
    await _verifyTraffic('s06-$phase-retry', expectedVpn: true);
    await _disconnectAndVerify('s06-$phase-retry');
    _event('s06_passed', {'phase': phase});
  }

  Future<void> _runS02() async {
    _event('s02_started');
    await _connectAndVerify('s02-first');
    await _verifyTraffic('s02-first', expectedVpn: true);
    await _disconnectAndVerify('s02-first');
    await _verifyTraffic('s02-direct', expectedVpn: false);
    await _connectAndVerify('s02-reconnect');
    await _verifyTraffic('s02-reconnect', expectedVpn: true);
    await _disconnectAndVerify('s02-final');
    _event('s02_passed');
  }

  Future<void> _connectAndVerify(String label) async {
    await notifier.toggleConnection().timeout(_connectTimeout);
    await _until(
      () {
        final app = container.read(connectionNotifierProvider).valueOrNull;
        final snapshot = core.authoritativeSessionSnapshot;
        return app is Connected && core.currentState is CoreStarted && snapshot?.provesConnected == true;
      },
      '$label connected',
      _connectTimeout,
    );
    _event('connected', {'label': label, ..._state()});
  }

  Future<void> _disconnectAndVerify(String label) async {
    await notifier.abortConnection().timeout(_cleanupTimeout);
    await _ensureStopped(label);
  }

  Future<void> _ensureStopped(String label) async {
    final app = container.read(connectionNotifierProvider).valueOrNull;
    if (app is Connected || app is Connecting || app is Disconnecting || core.currentState is! CoreStopped) {
      await notifier.abortConnection().timeout(_cleanupTimeout);
    }
    await _until(
      () {
        final current = container.read(connectionNotifierProvider).valueOrNull;
        final snapshot = core.authoritativeSessionSnapshot;
        return current is Disconnected &&
            core.currentState is CoreStopped &&
            snapshot?.provesConnected != true &&
            (snapshot == null ||
                snapshot.phase == VpnSessionPhase.idle ||
                snapshot.phase == VpnSessionPhase.disconnected ||
                snapshot.phase == VpnSessionPhase.failed);
      },
      '$label stopped',
      _cleanupTimeout,
    );
    _event('stopped', {'label': label, ..._state()});
  }

  Future<void> _verifyTraffic(String label, {required bool expectedVpn}) async {
    final snapshot = core.authoritativeSessionSnapshot;
    if (expectedVpn != (snapshot?.provesConnected == true)) {
      throw StateError('VPN ownership mismatch before $label traffic');
    }
    for (final raw in _trafficTargets) {
      final uri = Uri.parse(raw);
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final stopwatch = Stopwatch()..start();
      try {
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
        final response = await request.close().timeout(const Duration(seconds: 15));
        await response.drain<void>().timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw StateError('HTTPS status ${response.statusCode}');
        }
        traffic.add({
          'label': label,
          'target': '${uri.scheme}://${uri.host}${uri.path}',
          'expected_vpn': expectedVpn,
          'status': 'PASS',
          'http_status': response.statusCode,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
        });
      } finally {
        client.close(force: true);
      }
    }
    _event('traffic_verified', {'label': label, 'expected_vpn': expectedVpn, 'checks': _trafficTargets.length});
  }

  Map<String, Object?> _state() {
    final app = container.read(connectionNotifierProvider).valueOrNull;
    final snapshot = core.authoritativeSessionSnapshot;
    return {
      'application': switch (app) {
        Disconnected() => 'disconnected',
        Connecting() => 'connecting',
        Connected() => 'connected',
        Disconnecting() => 'disconnecting',
        _ => 'unknown',
      },
      'core': switch (core.currentState) {
        CoreStopped() => 'stopped',
        CoreStarting() => 'starting',
        CoreStarted() => 'started',
        CoreStopping() => 'stopping',
      },
      'generation': snapshot?.generation,
      'native_phase': snapshot?.phase.name,
      'native_ready': snapshot?.provesConnected,
      'stop_source': snapshot?.stopSource.name,
    };
  }

  void _event(String name, [Map<String, Object?> details = const {}]) {
    events.add({'utc': DateTime.now().toUtc().toIso8601String(), 'event': name, ...details});
  }
}

Future<void> _until(FutureOr<bool> Function() predicate, String label, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException(label, timeout);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _HarnessView());
  ProviderContainer? container;
  File? resultFile;
  final started = DateTime.now().toUtc();
  final result = <String, Object?>{
    'schema': 'zeon.android-runtime.v1',
    'source_sha': _sourceSha,
    'build_type': _buildType,
    'build_utc': _buildUtc,
    'started_utc': started.toIso8601String(),
  };
  try {
    container = await bootstrapAndroidRuntimeHarness(Environment.prod).timeout(const Duration(minutes: 4));
    final directories = await container.read(appDirectoriesProvider.future);
    resultFile = File('${directories.baseDir.path}${Platform.pathSeparator}android-runtime-result.json');
    final appInfo = await container.read(appInfoProvider.future);
    final harness = _AndroidRuntimeHarness(container);
    await harness.initialize();
    await harness.run();
    result.addAll({
      'verdict': 'PASS',
      'version': appInfo.version,
      'build_number': appInfo.buildNumber,
      'events': harness.events,
      'traffic': harness.traffic,
    });
  } catch (error, stackTrace) {
    result.addAll({
      'verdict': 'FAIL',
      'error_type': error.runtimeType.toString(),
      'error': error.toString(),
      'stack': stackTrace.toString().split('\n').take(12).toList(),
    });
    if (container != null) {
      try {
        await container.read(connectionNotifierProvider.notifier).abortConnection().timeout(_cleanupTimeout);
      } catch (_) {}
    }
  } finally {
    result['ended_utc'] = DateTime.now().toUtc().toIso8601String();
    result['duration_ms'] = DateTime.now().toUtc().difference(started).inMilliseconds;
    final json = '${const JsonEncoder.withIndent('  ').convert(result)}\n';
    await resultFile?.writeAsString(json, flush: true);
    stdout.writeln('ZEON_ANDROID_RUNTIME_RESULT=${jsonEncode(result)}');
  }
}
