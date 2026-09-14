// Dedicated finite validation executable, never a production entrypoint.
// Build only through `scripts/build.ps1 -Action windows-runtime`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/bootstrap.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/log/model/log_level.dart' as app_log;
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

import 'runtime_core_snapshot.dart' show resolveRuntimeLeaf, safeId, trimNativeTag;
import 'runtime_p03_r17_validation.dart';

const _sourceSha = String.fromEnvironment('zeon_source_sha');
const _buildType = String.fromEnvironment('zeon_build_type');
const _buildUtc = String.fromEnvironment('zeon_build_utc');
const _runtimeGuard = bool.fromEnvironment('zeon_runtime_validation');
const _defaultProxyPort = 13434;
const _cancelObservation = Duration(seconds: 150);

enum RuntimeScenario {
  preflight('preflight'),
  connect('connect'),
  s02('s02'),
  s06('s06'),
  manualProxy('manual-proxy'),
  autoProxy('auto-proxy'),
  p03R17('p03-r17'),
  p04('p04');

  const RuntimeScenario(this.cliName);
  final String cliName;

  static RuntimeScenario parse(String value) => values.firstWhere(
    (item) => item.cliName == value.toLowerCase(),
    orElse: () => throw FormatException('Unsupported scenario: $value'),
  );
}

enum HarnessMode {
  systemProxy('system-proxy', ServiceMode.systemProxy),
  tun('tun', ServiceMode.tun),
  localProxy('local-proxy', ServiceMode.proxy);

  const HarnessMode(this.cliName, this.serviceMode);
  final String cliName;
  final ServiceMode serviceMode;

  static HarnessMode parse(String value) => values.firstWhere(
    (item) => item.cliName == value.toLowerCase(),
    orElse: () => throw FormatException('Unsupported mode: $value'),
  );
}

enum RuntimeVerdict { pass, fail, harnessError, environmentError }

extension on RuntimeVerdict {
  String get wireName => switch (this) {
    RuntimeVerdict.pass => 'PASS',
    RuntimeVerdict.fail => 'FAIL',
    RuntimeVerdict.harnessError => 'HARNESS_ERROR',
    RuntimeVerdict.environmentError => 'ENVIRONMENT_ERROR',
  };

  int get exitCode => switch (this) {
    RuntimeVerdict.pass => 0,
    RuntimeVerdict.fail => 1,
    RuntimeVerdict.harnessError => 2,
    RuntimeVerdict.environmentError => 3,
  };
}

class RuntimeFailure implements Exception {
  const RuntimeFailure(this.verdict, this.reason, {this.timeoutKind, this.timeoutSeconds});

  final RuntimeVerdict verdict;
  final String reason;
  final String? timeoutKind;
  final int? timeoutSeconds;

  factory RuntimeFailure.fail(String reason) => RuntimeFailure(RuntimeVerdict.fail, reason);
  factory RuntimeFailure.harness(String reason) => RuntimeFailure(RuntimeVerdict.harnessError, reason);
  factory RuntimeFailure.environment(String reason) => RuntimeFailure(RuntimeVerdict.environmentError, reason);

  factory RuntimeFailure.deadline(String kind, Duration timeout, {RuntimeVerdict verdict = RuntimeVerdict.fail}) =>
      RuntimeFailure(
        verdict,
        '$kind timed out after ${timeout.inSeconds}s',
        timeoutKind: kind,
        timeoutSeconds: timeout.inSeconds,
      );

  @override
  String toString() => reason;
}

class RuntimeOptions {
  const RuntimeOptions({
    required this.scenario,
    required this.mode,
    required this.ipv6Mode,
    required this.evidenceDirectory,
    this.profileFile,
    required this.runId,
    required this.connectTimeout,
    required this.bootstrapTimeout,
    required this.cleanupTimeout,
    required this.scenarioTimeout,
    required this.trafficUrls,
    required this.backendHealthUrl,
    required this.s02Cycles,
    required this.proxyPort,
    required this.cancelPhase,
    this.manualProxyTag,
  });

  final RuntimeScenario scenario;
  final HarnessMode mode;
  final IPv6Mode ipv6Mode;
  final String evidenceDirectory;
  final String? profileFile;
  final String runId;
  final Duration connectTimeout;
  final Duration bootstrapTimeout;
  final Duration cleanupTimeout;
  final Duration scenarioTimeout;
  final List<Uri> trafficUrls;
  final Uri backendHealthUrl;
  final int s02Cycles;
  final int proxyPort;
  final String cancelPhase;
  final String? manualProxyTag;

  factory RuntimeOptions.parse(List<String> args, {Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final parsed = <String, List<String>>{};
    const valued = {
      'scenario',
      'mode',
      'ipv6-mode',
      'evidence-dir',
      'profile-file',
      'run-id',
      'connect-timeout-seconds',
      'bootstrap-timeout-seconds',
      'cleanup-timeout-seconds',
      'scenario-timeout-seconds',
      'traffic-url',
      'backend-health-url',
      's02-cycles',
      'proxy-port',
      'cancel-phase',
      'manual-proxy-tag',
    };
    for (var index = 0; index < args.length; index++) {
      final raw = args[index];
      if (!raw.startsWith('--')) throw FormatException('Unexpected positional argument: $raw');
      final separator = raw.indexOf('=');
      final name = raw.substring(2, separator < 0 ? raw.length : separator);
      if (!valued.contains(name)) throw FormatException('Unknown option: --$name');
      final value = separator >= 0
          ? raw.substring(separator + 1)
          : (++index < args.length ? args[index] : throw FormatException('Missing value for --$name'));
      if (value.isEmpty || value.startsWith('--')) throw FormatException('Missing value for --$name');
      parsed.putIfAbsent(name, () => []).add(value);
    }

    String? one(String name, String envName) {
      final values = parsed[name];
      if (values != null && values.length > 1) throw FormatException('--$name may be supplied only once');
      return values?.single ?? env[envName]?.trim().nullIfEmpty;
    }

    int integer(String name, String envName, int defaultValue, int min, int max) {
      final text = one(name, envName);
      final value = text == null ? defaultValue : int.tryParse(text);
      if (value == null || value < min || value > max) {
        throw FormatException('--$name must be an integer between $min and $max');
      }
      return value;
    }

    Uri httpsUri(String value, String name) {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw FormatException('$name must be an absolute HTTPS URL');
      }
      return uri;
    }

    final scenario = RuntimeScenario.parse(one('scenario', 'ZEON_RUNTIME_SCENARIO') ?? 'connect');
    final mode = HarnessMode.parse(one('mode', 'ZEON_RUNTIME_MODE') ?? 'system-proxy');
    final ipv6ModeKey = one('ipv6-mode', 'ZEON_RUNTIME_IPV6_MODE') ?? IPv6Mode.disable.key;
    final ipv6Mode = IPv6Mode.values.firstWhere(
      (item) => item.key == ipv6ModeKey,
      orElse: () => throw FormatException('Unsupported IPv6 mode: $ipv6ModeKey'),
    );
    final evidenceDirectory = one('evidence-dir', 'ZEON_RUNTIME_EVIDENCE_DIR');
    final profileFile = one('profile-file', 'ZEON_RUNTIME_PROFILE_FILE');
    final runId = one('run-id', 'ZEON_RUNTIME_RUN_ID');
    if (evidenceDirectory == null) throw const FormatException('Evidence directory is required');
    if (scenario != RuntimeScenario.preflight && profileFile == null) {
      throw const FormatException('Profile fixture file is required outside preflight');
    }
    if (runId == null || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$').hasMatch(runId)) {
      throw const FormatException('Run ID must contain 3-80 safe filename characters');
    }

    final connectSeconds = integer('connect-timeout-seconds', 'ZEON_RUNTIME_CONNECT_TIMEOUT_SECONDS', 45, 1, 45);
    final bootstrapSeconds = integer(
      'bootstrap-timeout-seconds',
      'ZEON_RUNTIME_BOOTSTRAP_TIMEOUT_SECONDS',
      240,
      30,
      600,
    );
    final cleanupSeconds = integer('cleanup-timeout-seconds', 'ZEON_RUNTIME_CLEANUP_TIMEOUT_SECONDS', 90, 15, 300);
    final defaultScenarioSeconds = switch (scenario) {
      RuntimeScenario.preflight => 300,
      RuntimeScenario.s02 => 3600,
      RuntimeScenario.s06 => 300,
      RuntimeScenario.manualProxy || RuntimeScenario.autoProxy || RuntimeScenario.p03R17 => 900,
      RuntimeScenario.p04 => 600,
      RuntimeScenario.connect => 300,
    };
    final scenarioSeconds = integer(
      'scenario-timeout-seconds',
      'ZEON_RUNTIME_SCENARIO_TIMEOUT_SECONDS',
      defaultScenarioSeconds,
      60,
      7200,
    );
    final trafficValues =
        parsed['traffic-url'] ??
        env['ZEON_RUNTIME_TRAFFIC_URLS']
            ?.split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList() ??
        const ['https://speed.cloudflare.com/__down?bytes=4096', 'https://captive.apple.com/hotspot-detect.html'];
    if (trafficValues.isEmpty) throw const FormatException('At least one traffic URL is required');
    final trafficUrls = trafficValues.map((value) => httpsUri(value, 'Traffic URL')).toList(growable: false);
    final backendHealthUrl = httpsUri(
      one('backend-health-url', 'ZEON_RUNTIME_BACKEND_HEALTH_URL') ?? 'https://api.zeon-vps.online/health',
      'Backend health URL',
    );
    final cancelPhase = one('cancel-phase', 'ZEON_RUNTIME_CANCEL_PHASE') ?? 'core-starting';
    if (!const {'app-connecting', 'core-starting'}.contains(cancelPhase)) {
      throw const FormatException('--cancel-phase must be app-connecting or core-starting');
    }

    return RuntimeOptions(
      scenario: scenario,
      mode: mode,
      ipv6Mode: ipv6Mode,
      evidenceDirectory: evidenceDirectory,
      profileFile: profileFile,
      runId: runId,
      connectTimeout: Duration(seconds: connectSeconds),
      bootstrapTimeout: Duration(seconds: bootstrapSeconds),
      cleanupTimeout: Duration(seconds: cleanupSeconds),
      scenarioTimeout: Duration(seconds: scenarioSeconds),
      trafficUrls: trafficUrls,
      backendHealthUrl: backendHealthUrl,
      s02Cycles: integer('s02-cycles', 'ZEON_RUNTIME_S02_CYCLES', 1, 1, 100),
      proxyPort: integer('proxy-port', 'ZEON_RUNTIME_PROXY_PORT', _defaultProxyPort, 1024, 65535),
      cancelPhase: cancelPhase,
      manualProxyTag: one('manual-proxy-tag', 'ZEON_RUNTIME_MANUAL_PROXY_TAG'),
    );
  }

  Map<String, Object?> toJson() => {
    'scenario': scenario.cliName,
    'mode': mode.cliName,
    'ipv6_mode': ipv6Mode.key,
    'run_id': runId,
    'timeouts_seconds': {
      'connect_readiness': connectTimeout.inSeconds,
      'bootstrap': bootstrapTimeout.inSeconds,
      'cleanup_diagnostic': cleanupTimeout.inSeconds,
      'scenario': scenarioTimeout.inSeconds,
      's06_late_activation_observation': _cancelObservation.inSeconds,
    },
    's02_cycles': s02Cycles,
    'proxy_port': proxyPort,
    'cancel_phase': cancelPhase,
    'traffic_targets': trafficUrls.map(_safeUri).toList(growable: false),
    'backend_health_target': _safeUri(backendHealthUrl),
  };
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

String _safeUri(Uri uri) => '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}';

class HarnessReporter {
  HarnessReporter(this.options, this.directory)
    : startedUtc = DateTime.now().toUtc(),
      eventsFile = File('${directory.path}${Platform.pathSeparator}events.jsonl'),
      resultFile = File('${directory.path}${Platform.pathSeparator}result.json');

  final RuntimeOptions options;
  final Directory directory;
  final DateTime startedUtc;
  final File eventsFile;
  final File resultFile;
  final Map<String, Map<String, Object?>> phaseTimestamps = {};
  final List<Map<String, Object?>> trafficResults = [];
  final List<Map<String, Object?>> cleanupAttempts = [];
  final List<String> evidencePaths = [];
  Future<void> _eventTail = Future<void>.value();
  bool _eventsSealed = false;
  String phase = 'bootstrap';
  RuntimeVerdict verdict = RuntimeVerdict.harnessError;
  String reason = 'runtime did not reach a terminal result';
  Map<String, Object?> appState = const {};
  Map<String, Object?> nativeState = const {};
  String machine = '';
  String appVersion = '';
  String buildNumber = '';

  Future<void> event(String name, [Map<String, Object?> details = const {}]) {
    if (_eventsSealed) return Future<void>.value();
    final payload = jsonEncode({
      'utc': DateTime.now().toUtc().toIso8601String(),
      'run_id': options.runId,
      'scenario': options.scenario.cliName,
      'mode': options.mode.cliName,
      'phase': phase,
      'event': name,
      ...details,
    });
    return _eventTail = _eventTail.then(
      (_) => eventsFile.writeAsString('$payload\n', mode: FileMode.append, flush: true),
    );
  }

  Future<void> sealEvents() async {
    _eventsSealed = true;
    final payload = jsonEncode({
      'utc': DateTime.now().toUtc().toIso8601String(),
      'run_id': options.runId,
      'scenario': options.scenario.cliName,
      'mode': options.mode.cliName,
      'phase': phase,
      'event': 'event_stream_sealed',
    });
    await (_eventTail = _eventTail.then(
      (_) => eventsFile.writeAsString('$payload\n', mode: FileMode.append, flush: true),
    ));
  }

  Future<void> startPhase(String name) async {
    phase = name;
    phaseTimestamps[name] = {'started_utc': DateTime.now().toUtc().toIso8601String()};
    await event('phase_started');
  }

  Future<void> endPhase({String status = 'completed', String? phaseReason}) async {
    final entry = phaseTimestamps.putIfAbsent(phase, () => <String, Object?>{});
    entry['ended_utc'] = DateTime.now().toUtc().toIso8601String();
    entry['status'] = status;
    if (phaseReason != null) entry['reason'] = phaseReason;
    await event('phase_ended', {'status': status, if (phaseReason != null) 'reason': phaseReason});
  }

  void addEvidence(String path) {
    if (!evidencePaths.contains(path)) evidencePaths.add(path);
  }

  Future<void> writeResult() async {
    final endedUtc = DateTime.now().toUtc();
    final result = {
      'schema': 'zeon.windows-runtime.v1',
      'verdict': verdict.wireName,
      'reason': reason,
      'run_id': options.runId,
      'started_utc': startedUtc.toIso8601String(),
      'ended_utc': endedUtc.toIso8601String(),
      'duration_ms': endedUtc.difference(startedUtc).inMilliseconds,
      'application': {
        'version': appVersion,
        'build_number': buildNumber,
        'commit_sha': _sourceSha,
        'build_type': _buildType,
        'build_utc': _buildUtc,
      },
      'machine': machine,
      'mode': options.mode.cliName,
      'scenario': options.scenario.cliName,
      'options': options.toJson(),
      'phase_timestamps': phaseTimestamps,
      'application_state': appState,
      'native_core_state': nativeState,
      'network_traffic': trafficResults,
      'cleanup': {
        'verified': cleanupAttempts.isNotEmpty && cleanupAttempts.last['verified'] == true,
        'attempts': cleanupAttempts,
      },
      'evidence_paths': evidencePaths,
    };
    await resultFile.writeAsString('${const JsonEncoder.withIndent('  ').convert(result)}\n', flush: true);
  }
}

class RegistryValueSnapshot {
  const RegistryValueSnapshot(this.name, this.type, this.data);
  final String name;
  final String? type;
  final String? data;
  bool get exists => type != null;

  Map<String, Object?> toJson() => {
    'exists': exists,
    if (exists) 'type': type,
    if (exists) 'data_length': data?.length ?? 0,
  };
}

class NetworkBaseline {
  NetworkBaseline(this.values, this.winHttp);
  final Map<String, RegistryValueSnapshot> values;
  final String winHttp;

  static const _internetSettings = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const names = ['ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL'];

  static Future<NetworkBaseline> capture() async {
    final values = <String, RegistryValueSnapshot>{};
    for (final name in names) {
      final result = await Process.run('reg.exe', ['query', _internetSettings, '/v', name]);
      if (result.exitCode == 1) {
        values[name] = RegistryValueSnapshot(name, null, null);
        continue;
      }
      if (result.exitCode != 0) throw RuntimeFailure.environment('Unable to capture WinINet value $name');
      final match = RegExp(
        '^\\s*${RegExp.escape(name)}\\s+(REG_\\w+)\\s+(.*)\$',
        multiLine: true,
      ).firstMatch(result.stdout as String);
      if (match == null) throw RuntimeFailure.environment('Unable to parse WinINet value $name');
      values[name] = RegistryValueSnapshot(name, match.group(1), match.group(2)?.trim() ?? '');
    }
    final winHttp = await Process.run('netsh.exe', ['winhttp', 'show', 'proxy']);
    if (winHttp.exitCode != 0) throw RuntimeFailure.environment('Unable to capture WinHTTP proxy state');
    return NetworkBaseline(values, (winHttp.stdout as String).trim());
  }

  Future<void> restore() async {
    for (final value in values.values) {
      final result = value.exists
          ? await Process.run('reg.exe', [
              'add',
              _internetSettings,
              '/v',
              value.name,
              '/t',
              value.type!,
              '/d',
              value.data!,
              '/f',
            ])
          : await Process.run('reg.exe', ['delete', _internetSettings, '/v', value.name, '/f']);
      if (result.exitCode != 0 && !(result.exitCode == 1 && !value.exists)) {
        throw RuntimeFailure.harness('Unable to restore WinINet value ${value.name}');
      }
    }
    final refreshed = await Process.run('netsh.exe', ['winhttp', 'show', 'proxy']);
    if (refreshed.exitCode != 0 || (refreshed.stdout as String).trim() != winHttp) {
      throw RuntimeFailure.fail('WinHTTP proxy state changed during the scenario');
    }
  }
}

class RuntimeHarness {
  RuntimeHarness(this.options, this.reporter);

  final RuntimeOptions options;
  final HarnessReporter reporter;
  ProviderContainer? container;
  NetworkBaseline? baseline;
  ServiceMode? originalMode;
  IPv6Mode? originalIPv6Mode;
  int? originalMixedPort;
  String? originalProxySelection;
  ProviderSubscription<AsyncValue<ConnectionStatus>>? appSubscription;
  ProviderSubscription<AsyncValue<OutboundGroup?>>? proxyKeepAlive;
  // Process-bound by design; see prepareForProcessExit.
  // ignore: cancel_subscriptions
  StreamSubscription<CoreStatus>? coreSubscription;

  ZeonCoreService get coreService => container!.read(zeonCoreServiceProvider);

  Future<void> initialize() async {
    await reporter.startPhase('environment');
    await _validateMachine();
    baseline = await NetworkBaseline.capture();
    await reporter.event('network_baseline_captured', {
      'wininet': baseline!.values.map((key, value) => MapEntry(key, value.toJson())),
      'winhttp': baseline!.winHttp,
    });
    await reporter.endPhase();

    await reporter.startPhase('bootstrap');
    container = await bootstrapWindowsRuntimeHarness(Environment.prod).timeout(
      options.bootstrapTimeout,
      onTimeout: () => throw RuntimeFailure.deadline(
        'bootstrap',
        options.bootstrapTimeout,
        verdict: RuntimeVerdict.environmentError,
      ),
    );
    final appInfo = await container!.read(appInfoProvider.future).timeout(options.bootstrapTimeout);
    reporter.appVersion = appInfo.version;
    reporter.buildNumber = appInfo.buildNumber;
    await container!.read(connectionNotifierProvider.future).timeout(options.bootstrapTimeout);
    appSubscription = container!.listen(connectionNotifierProvider, (_, next) {
      reporter.appState = _appStateJson(next);
      unawaited(reporter.event('application_state', reporter.appState));
    }, fireImmediately: true);
    coreSubscription = coreService.statusController.listen((status) {
      reporter.nativeState = _coreStateJson(status);
      unawaited(reporter.event('native_core_state', reporter.nativeState));
    });

    await container!.read(Preferences.introCompleted.notifier).update(true);
    if (options.scenario != RuntimeScenario.preflight) {
      await _ensureProfile();
    }
    originalMode = container!.read(ConfigOptions.serviceMode);
    originalIPv6Mode = container!.read(ConfigOptions.ipv6Mode);
    originalMixedPort = container!.read(ConfigOptions.mixedPort);
    await container!.read(ConfigOptions.mixedPort.notifier).update(options.proxyPort);
    if (Platform.environment['ZEON_RUNTIME_NATIVE_DEBUG'] == '1') {
      await container!.read(ConfigOptions.logLevel.notifier).update(app_log.LogLevel.debug);
    }
    if (await _proxyListening()) throw RuntimeFailure.environment('Harness proxy port is occupied before connect');
    await reporter.event('bootstrap_ready', {
      'app_version': reporter.appVersion,
      'build_number': reporter.buildNumber,
      'commit_sha': _sourceSha,
    });
    await _networkSnapshot('before-scenario');
    await reporter.endPhase();
  }

  Future<void> run() async {
    await _prepareMode();
    var cleanupOk = false;
    try {
      await reporter.startPhase('scenario-${options.scenario.cliName}');
      try {
        await switch (options.scenario) {
          RuntimeScenario.preflight => _scenarioPreflight(),
          RuntimeScenario.connect => _scenarioConnect(),
          RuntimeScenario.s02 => _scenarioS02(),
          RuntimeScenario.s06 => _scenarioS06(),
          RuntimeScenario.manualProxy => _scenarioManualProxy(),
          RuntimeScenario.autoProxy => _scenarioAutoProxy(),
          RuntimeScenario.p03R17 => _scenarioP03R17(),
          RuntimeScenario.p04 => _scenarioP04(),
        }.timeout(
          options.scenarioTimeout,
          onTimeout: () => throw RuntimeFailure.deadline('scenario', options.scenarioTimeout),
        );
        await reporter.endPhase(status: 'passed');
      } catch (error) {
        await reporter.endPhase(status: 'failed', phaseReason: error.toString());
        rethrow;
      }
    } finally {
      cleanupOk = await cleanup(label: 'scenario-finally');
    }
    if (!cleanupOk) {
      throw RuntimeFailure.fail('Scenario passed but cleanup verification failed');
    }
  }

  Future<void> _scenarioPreflight() async {
    if (container!.read(connectionNotifierProvider).valueOrNull is! Disconnected) {
      throw RuntimeFailure.environment('Application is not disconnected at preflight boundary');
    }
    if (coreService.currentState is! CoreStopped) {
      throw RuntimeFailure.environment('Native core is not stopped at preflight boundary');
    }
    if (await _proxyListening()) {
      throw RuntimeFailure.environment('Proxy listener exists at preflight boundary');
    }
    reporter.appState = _appStateJson(container!.read(connectionNotifierProvider));
    reporter.nativeState = _coreStateJson(coreService.currentState);
    await reporter.event('harness_preflight_passed', {
      'application_state': reporter.appState,
      'native_core_state': reporter.nativeState,
      'ui_created': false,
    });
  }

  Future<void> _scenarioConnect() async {
    await _connectAndProveReady();
    await _reportSelectedOutbound();
    await _verifyTraffic();
    await _disconnectAndVerify('connect-scenario');
  }

  Future<void> _scenarioS02() async {
    for (var cycle = 1; cycle <= options.s02Cycles; cycle++) {
      await reporter.event('s02_cycle_started', {'cycle': cycle, 'total': options.s02Cycles});
      await _connectAndProveReady();
      await _reportSelectedOutbound();
      await _verifyTraffic(verifyProductHealth: false);
      await _disconnectAndVerify('s02-cycle-$cycle-first-stop');
      await _verifyDirectTraffic(cycle);
      await _connectAndProveReady();
      await _reportSelectedOutbound();
      await _verifyTraffic(verifyProductHealth: false);
      await _disconnectAndVerify('s02-cycle-$cycle-final-stop');
      await reporter.event('s02_cycle_passed', {'cycle': cycle});
    }
  }

  Future<void> _scenarioS06() async {
    final notifier = container!.read(connectionNotifierProvider.notifier);
    final operation = notifier.toggleConnection();
    await reporter.event('connect_dispatched_for_cancel', {'target_phase': options.cancelPhase});
    await _until(
      () {
        final app = container!.read(connectionNotifierProvider).valueOrNull;
        final core = coreService.currentState;
        return options.cancelPhase == 'app-connecting' ? app is Connecting : app is Connecting && core is CoreStarting;
      },
      'observable ${options.cancelPhase} phase',
      options.connectTimeout,
    );
    await reporter.event('cancel_phase_observed', {
      'application_state': _appStateJson(container!.read(connectionNotifierProvider)),
      'native_core_state': _coreStateJson(coreService.currentState),
    });
    await notifier.abortConnection().timeout(options.cleanupTimeout);
    try {
      await operation.timeout(options.cleanupTimeout);
    } catch (error) {
      await reporter.event('superseded_connect_completed_with_error', {'error_type': error.runtimeType.toString()});
    }
    await _verifyStopped('s06-cancel');

    final deadline = DateTime.now().add(_cancelObservation);
    while (DateTime.now().isBefore(deadline)) {
      final app = container!.read(connectionNotifierProvider).valueOrNull;
      if (app is Connected || app is Connecting || coreService.currentState is CoreStarted || await _proxyListening()) {
        throw RuntimeFailure.fail('S06 late activation observed after cancellation');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await reporter.event('s06_no_late_activation', {'observed_seconds': _cancelObservation.inSeconds});
    await _connectAndProveReady();
    await _reportSelectedOutbound();
    await _verifyTraffic(verifyProductHealth: false);
    await _disconnectAndVerify('s06-retry');
    await reporter.event('s06_retry_passed');
  }

  Future<void> _scenarioManualProxy() async {
    await _connectAndProveReady();
    final group = await _selectorGroup();
    originalProxySelection ??= group.selected;
    final manual = options.manualProxyTag == null
        ? group.items.firstWhere(
            (item) =>
                item.isVisible &&
                !const {'balance', 'urltest', 'direct', 'block', 'dns'}.contains(item.tag) &&
                !const {'selector', 'balancer', 'urltest', 'direct', 'block', 'dns'}.contains(item.type),
            orElse: () => throw RuntimeFailure.environment('No safe manual proxy fixture is available'),
          )
        : group.items.firstWhere(
            (item) => item.tag == options.manualProxyTag,
            orElse: () => throw RuntimeFailure.environment('Requested manual proxy fixture is unavailable'),
          );
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, manual.tag);
    await _verifyTraffic();
    final systemInfo = await coreService.core.backgroundCommandClient
        .getSystemInfo(Empty())
        .timeout(const Duration(seconds: 8));
    if (systemInfo.currentOutbound != manual.tag) {
      throw RuntimeFailure.fail('Manual proxy selection differs from native runtime');
    }
    await reporter.event('manual_proxy_verified', {'outbound_id': await safeId(manual.tag)});
    await _disconnectAndVerify('manual-proxy');
  }

  Future<void> _scenarioAutoProxy() async {
    await _connectAndProveReady();
    final group = await _selectorGroup();
    originalProxySelection ??= group.selected;
    final auto = group.items.firstWhere(
      (item) => item.tag == 'balance' || item.type == 'balancer',
      orElse: () => throw RuntimeFailure.environment('Automatic proxy selector is unavailable'),
    );
    final manual = group.items.firstWhere(
      (item) =>
          item.isVisible &&
          item.tag != auto.tag &&
          !const {'selector', 'urltest', 'direct', 'block', 'dns', 'balancer'}.contains(item.type),
      orElse: () => throw RuntimeFailure.environment('No manual proxy is available before Auto transition'),
    );
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, manual.tag);
    await _verifyNativeSelection(group.tag, manual.tag, requireConcreteLeaf: false);
    await _verifyTraffic();
    await reporter.event('auto_proxy_manual_precondition_verified', {'manual_outbound_id': await safeId(manual.tag)});
    await _disconnectAndVerify('auto-proxy-manual-stage');
    await _connectAndProveReady();
    await _verifyNativeSelection(group.tag, manual.tag, requireConcreteLeaf: false);
    await reporter.event('auto_proxy_manual_reconnect_verified', {'manual_outbound_id': await safeId(manual.tag)});
    // Exact R08 order: Auto is a live user choice only after the second
    // connection has become ready with the persisted manual server.
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, auto.tag);
    await _verifyNativeSelectorTag(group.tag, auto.tag);
    await _verifyTraffic();
    final leaf = await _waitForConcreteNativeLeaf(group.tag, auto.tag);
    await reporter.event('auto_proxy_verified', {
      'selector_id': await safeId(auto.tag),
      'runtime_outbound_id': await safeId(leaf.tag),
      'exact_r08_order': true,
    });
    await _disconnectAndVerify('auto-proxy');
  }

  Future<void> _scenarioP03R17() async {
    final validation = RuntimeP03R17Validation(container!);
    await reporter.event('p03_data_checks_started');
    await reporter.event('p03_data_checks_passed', await validation.runDataAndErrorChecks());

    await reporter.event('r17_disconnected_refresh_started');
    final disconnectedRefresh = await validation.refreshActiveRemoteProfile();
    if (container!.read(connectionNotifierProvider).valueOrNull is! Disconnected ||
        coreService.currentState is! CoreStopped ||
        await _proxyListening()) {
      throw RuntimeFailure.fail('R17 disconnected refresh changed VPN runtime ownership');
    }
    await _verifyDirectTraffic(0);
    await reporter.event('r17_disconnected_refresh_passed', disconnectedRefresh);

    await _connectAndProveReady();
    var group = await _selectorGroup();
    originalProxySelection ??= group.selected;
    final auto = group.items.firstWhere(
      (item) => item.tag == 'balance' || item.type == 'balancer',
      orElse: () => throw RuntimeFailure.environment('Automatic proxy selector is unavailable'),
    );
    final manual = group.items.firstWhere(
      (item) =>
          item.isVisible &&
          item.tag != auto.tag &&
          !const {'selector', 'urltest', 'direct', 'block', 'dns', 'balancer'}.contains(item.type),
      orElse: () => throw RuntimeFailure.environment('No manual proxy is available for R17'),
    );
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, manual.tag);
    await _verifyNativeSelection(group.tag, manual.tag, requireConcreteLeaf: false);
    await _verifyTraffic();

    var observedStopping = false;
    var observedStarting = false;
    final restartSubscription = coreService.statusController.stream.listen((state) {
      observedStopping = observedStopping || state is CoreStopping;
      observedStarting = observedStarting || state is CoreStarting;
    });
    try {
      await reporter.event('r17_connected_refresh_started', {'manual_outbound_id': await safeId(manual.tag)});
      final connectedRefresh = await validation.refreshActiveRemoteProfile();
      await _until(
        () async =>
            container!.read(connectionNotifierProvider).valueOrNull is Connected &&
            coreService.currentState is CoreStarted &&
            await _proxyListening(),
        'R17 connected refresh readiness',
        options.connectTimeout,
      );
      group = await _selectorGroup();
      await _verifyNativeSelection(group.tag, manual.tag, requireConcreteLeaf: false);
      await _verifyTraffic();
      if (!observedStopping || !observedStarting) {
        throw RuntimeFailure.fail('R17 connected refresh did not prove a native restart');
      }
      await reporter.event('r17_connected_refresh_passed', {
        ...connectedRefresh,
        'manual_outbound_preserved': true,
        'native_restart_observed': true,
      });
    } finally {
      await restartSubscription.cancel();
    }

    group = await _selectorGroup();
    final refreshedAuto = group.items.firstWhere(
      (item) => item.tag == auto.tag,
      orElse: () => throw RuntimeFailure.fail('Auto selector disappeared after R17 refresh'),
    );
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, refreshedAuto.tag);
    await _verifyNativeSelectorTag(group.tag, refreshedAuto.tag);
    await _verifyTraffic();
    final leaf = await _waitForConcreteNativeLeaf(group.tag, refreshedAuto.tag);
    await reporter.event('task05_auto_after_profile_refresh_passed', {
      'selector_id': await safeId(refreshedAuto.tag),
      'runtime_outbound_id': await safeId(leaf.tag),
    });

    await _disconnectAndVerify('p03-r17');
    await reporter.event('p03_key_loss_started');
    await reporter.event('p03_key_loss_passed', await validation.runKeyLossCheckAndRestore());
  }

  Future<void> _scenarioP04() async {
    await _connectAndProveReady();
    final group = await _selectorGroup();
    originalProxySelection ??= group.selected;
    final auto = group.items.firstWhere(
      (item) => item.tag == 'balance' || item.type == 'balancer',
      orElse: () => throw RuntimeFailure.environment('Smart Active Auto selector is unavailable'),
    );
    if (group.selected != auto.tag) {
      await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, auto.tag);
    }
    await _verifyNativeSelectorTag(group.tag, auto.tag);
    await container!.read(proxiesOverviewNotifierProvider.notifier).urlTest(group.tag);

    final capability = await _waitForP04Capability(group.tag);
    await _verifyTraffic(verifyProductHealth: false);
    final selected = await _p04SelectionSnapshot(group.tag, auto.tag);
    final supported = capability.where((item) => item.ipv6Status == 'supported').toList(growable: false);
    final selectedStatus = selected.ipv6Status.isEmpty ? 'not_tested' : selected.ipv6Status;
    final observation = {
      'ipv6_mode': options.ipv6Mode.key,
      'transport_mode': options.mode.cliName,
      'candidate_count': capability.length,
      'supported_count': supported.length,
      'unavailable_count': capability.where((item) => item.ipv6Status == 'unavailable').length,
      'indeterminate_count': capability.where((item) => item.ipv6Status == 'indeterminate').length,
      'not_tested_count': capability.where((item) => item.ipv6Status.isEmpty || item.ipv6Status == 'not_tested').length,
      'selected_leaf_id': await safeId(selected.tag),
      'selected_ipv6_status': selectedStatus,
      'smart_active': true,
    };
    await reporter.event('p04_capability_observed', observation);

    if (options.ipv6Mode == IPv6Mode.disable) {
      if (capability.any((item) => item.ipv6Status.isNotEmpty && item.ipv6Status != 'not_tested')) {
        throw RuntimeFailure.fail('ipv4_only unexpectedly executed IPv6 capability probes');
      }
    } else if (options.ipv6Mode == IPv6Mode.prefer && supported.isNotEmpty && selectedStatus != 'supported') {
      throw RuntimeFailure.fail('prefer_ipv6 did not choose from the verified IPv6 pool');
    } else if (options.ipv6Mode == IPv6Mode.only && selectedStatus != 'supported') {
      throw RuntimeFailure.fail('ipv6_only selected a leaf without verified IPv6 capability');
    }

    await reporter.event('p04_smart_active_verified', observation);
    await _disconnectAndVerify('p04');
  }

  Future<List<OutboundInfo>> _waitForP04Capability(String groupTag) async {
    const timeout = Duration(seconds: 180);
    final deadline = DateTime.now().add(timeout);
    do {
      final groups = await coreService.core.backgroundCommandClient
          .outboundsInfo(Empty())
          .first
          .timeout(const Duration(seconds: 8));
      final leaves = _p04Leaves(groups, groupTag);
      if (leaves.isNotEmpty) {
        if (options.ipv6Mode == IPv6Mode.disable) {
          await Future<void>.delayed(const Duration(seconds: 3));
          final confirmation = await coreService.core.backgroundCommandClient
              .outboundsInfo(Empty())
              .first
              .timeout(const Duration(seconds: 8));
          return _p04Leaves(confirmation, groupTag);
        }
        final terminal = leaves.where(
          (item) => const {'supported', 'unavailable', 'indeterminate'}.contains(item.ipv6Status),
        );
        // Smart Active ranks a coherent completed cohort. Returning after the
        // first IPv6-capable leaf races that decision and can observe the
        // previously active leaf while the rest of the selector is checking.
        if (terminal.length == leaves.length) {
          return leaves;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } while (DateTime.now().isBefore(deadline));
    throw RuntimeFailure.deadline('P04 IPv6 capability readiness', timeout);
  }

  List<OutboundInfo> _p04Leaves(OutboundGroupList groups, String groupTag) {
    final selector = groups.items.firstWhere(
      (item) => item.tag == groupTag,
      orElse: () => throw RuntimeFailure.fail('P04 selector group disappeared during capability check'),
    );
    return selector.items
        .where((item) => !item.isGroup && item.isVisible && !const {'direct', 'block', 'dns'}.contains(item.type))
        .toList(growable: false);
  }

  Future<OutboundInfo> _p04SelectionSnapshot(String groupTag, String autoTag) async {
    const timeout = Duration(seconds: 30);
    final deadline = DateTime.now().add(timeout);
    do {
      final groups = await coreService.core.backgroundCommandClient
          .outboundsInfo(Empty())
          .first
          .timeout(const Duration(seconds: 8));
      final currentGroup = groups.items.firstWhere(
        (item) => item.tag == groupTag,
        orElse: () => throw RuntimeFailure.fail('P04 selector group disappeared'),
      );
      if (currentGroup.selected != autoTag) {
        throw RuntimeFailure.fail('P04 Smart Active selector changed unexpectedly');
      }
      final systemInfo = await coreService.core.backgroundCommandClient
          .getSystemInfo(Empty())
          .timeout(const Duration(seconds: 8));
      final leaf = resolveRuntimeLeaf(groups, systemInfo.currentOutbound);
      if (leaf != null) {
        final selectorLeaf = currentGroup.items.where(
          (item) => !item.isGroup && trimNativeTag(item.tag) == trimNativeTag(leaf.tag),
        );
        if (selectorLeaf.length == 1) return selectorLeaf.single;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } while (DateTime.now().isBefore(deadline));
    throw RuntimeFailure.deadline('P04 concrete Smart Active leaf', timeout);
  }

  Future<OutboundInfo?> _verifyNativeSelection(
    String groupTag,
    String selectedTag, {
    required bool requireConcreteLeaf,
  }) async {
    final groups = await coreService.core.backgroundCommandClient
        .outboundsInfo(Empty())
        .first
        .timeout(const Duration(seconds: 8));
    final currentGroup = groups.items.firstWhere(
      (item) => item.tag == groupTag,
      orElse: () => throw RuntimeFailure.fail('Native selector group disappeared'),
    );
    if (currentGroup.selected != selectedTag) {
      throw RuntimeFailure.fail('Requested selection was not applied by native runtime');
    }
    final systemInfo = await coreService.core.backgroundCommandClient
        .getSystemInfo(Empty())
        .timeout(const Duration(seconds: 8));
    if (!requireConcreteLeaf) {
      if (systemInfo.currentOutbound != selectedTag) {
        throw RuntimeFailure.fail('Manual selection differs from native runtime');
      }
      return null;
    }
    final leaf = resolveRuntimeLeaf(groups, systemInfo.currentOutbound);
    if (leaf == null) throw RuntimeFailure.fail('Auto selection has no concrete native outbound');
    return leaf;
  }

  Future<void> _verifyNativeSelectorTag(String groupTag, String selectedTag) async {
    final groups = await coreService.core.backgroundCommandClient
        .outboundsInfo(Empty())
        .first
        .timeout(const Duration(seconds: 8));
    final currentGroup = groups.items.firstWhere(
      (item) => item.tag == groupTag,
      orElse: () => throw RuntimeFailure.fail('Native selector group disappeared'),
    );
    if (currentGroup.selected != selectedTag) {
      throw RuntimeFailure.fail('Requested selection was not applied by native runtime');
    }
  }

  Future<OutboundInfo> _waitForConcreteNativeLeaf(String groupTag, String selectedTag) async {
    const timeout = Duration(seconds: 30);
    final deadline = DateTime.now().add(timeout);
    do {
      try {
        final groups = await coreService.core.backgroundCommandClient
            .outboundsInfo(Empty())
            .first
            .timeout(const Duration(seconds: 8));
        final currentGroup = groups.items.firstWhere(
          (item) => item.tag == groupTag,
          orElse: () => throw RuntimeFailure.fail('Native selector group disappeared after Auto traffic'),
        );
        if (currentGroup.selected != selectedTag) {
          throw RuntimeFailure.fail('Native selector changed during Auto traffic');
        }
        final systemInfo = await coreService.core.backgroundCommandClient
            .getSystemInfo(Empty())
            .timeout(const Duration(seconds: 8));
        final leaf = resolveRuntimeLeaf(groups, systemInfo.currentOutbound);
        if (leaf != null) return leaf;
      } on GrpcError {
        if (container!.read(connectionNotifierProvider).valueOrNull is! Connected ||
            coreService.currentState is! CoreStarted) {
          rethrow;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } while (DateTime.now().isBefore(deadline));
    throw RuntimeFailure.deadline('Auto concrete native outbound after traffic', timeout);
  }

  Future<void> _prepareMode() async {
    await container!.read(ConfigOptions.serviceMode.notifier).update(options.mode.serviceMode);
    if (options.scenario == RuntimeScenario.p04) {
      await container!.read(ConfigOptions.ipv6Mode.notifier).update(options.ipv6Mode);
    }
    await reporter.event('service_mode_selected', {'service_mode': options.mode.serviceMode.name});
  }

  Future<void> _connectAndProveReady() async {
    final stopwatch = Stopwatch()..start();
    Duration remaining() {
      final value = options.connectTimeout - stopwatch.elapsed;
      if (value <= Duration.zero) {
        throw RuntimeFailure.deadline('connect readiness', options.connectTimeout);
      }
      return value;
    }

    await reporter.event('connect_requested', {'readiness_budget_seconds': options.connectTimeout.inSeconds});
    final operation = container!.read(connectionNotifierProvider.notifier).toggleConnection();
    try {
      await _until(
        () => container!.read(connectionNotifierProvider).valueOrNull is Connected,
        'application connected readiness',
        options.connectTimeout,
      );
      await operation.timeout(
        remaining(),
        onTimeout: () => throw RuntimeFailure.deadline('connect operation', options.connectTimeout),
      );
      await _until(_proxyListening, 'local proxy listener readiness', remaining());
      final coreInfo = await coreService.core.backgroundCommandClient
          .coreInfoListener(Empty())
          .first
          .timeout(
            remaining(),
            onTimeout: () => throw RuntimeFailure.deadline('native core readiness', options.connectTimeout),
          );
      if (coreInfo.coreState != CoreStates.STARTED) throw RuntimeFailure.fail('Native core did not report STARTED');
      await reporter.event('connection_ready', {'elapsed_ms': stopwatch.elapsedMilliseconds});
      await _networkSnapshot('connected');
    } on RuntimeFailure catch (error) {
      if (error.timeoutKind != null) {
        await reporter.event('connect_timeout_cancellation_started', {'timeout_kind': error.timeoutKind});
        try {
          await container!.read(connectionNotifierProvider.notifier).abortConnection().timeout(options.cleanupTimeout);
          await coreService.stop(force: true).run().timeout(options.cleanupTimeout);
          await _verifyStopped('connect-timeout-cancellation');
          await reporter.event('connect_timeout_cancellation_completed');
        } catch (cancelError) {
          await reporter.event('connect_timeout_cancellation_failed', {
            'error_type': cancelError.runtimeType.toString(),
          });
        }
        unawaited(operation.catchError((_) {}));
      }
      rethrow;
    }
  }

  Future<void> _disconnectAndVerify(String label) async {
    await container!.read(connectionNotifierProvider.notifier).abortConnection().timeout(options.cleanupTimeout);
    await _verifyStopped(label);
    await _networkSnapshot('$label-disconnected');
  }

  Future<void> _verifyStopped(String label) async {
    await _until(
      () => container!.read(connectionNotifierProvider).valueOrNull is Disconnected,
      '$label application disconnect',
      options.cleanupTimeout,
    );
    await _until(() async => !await _proxyListening(), '$label proxy listener cleanup', options.cleanupTimeout);
    if (coreService.currentState is CoreStarted || coreService.currentState is CoreStarting) {
      throw RuntimeFailure.fail('$label native core remained active');
    }
    await reporter.event('cleanup_boundary_verified', {'label': label});
  }

  Future<OutboundGroup> _selectorGroup() async {
    proxyKeepAlive ??= container!.listen(proxiesOverviewNotifierProvider, (_, _) {});
    final group = await container!.read(proxiesOverviewNotifierProvider.future).timeout(const Duration(seconds: 15));
    if (group == null) throw RuntimeFailure.environment('Proxy selector fixture is unavailable');
    return group;
  }

  Future<void> _reportSelectedOutbound() async {
    final group = await _selectorGroup();
    String? selectedType;
    var selectedIsGroup = false;
    for (final item in group.items) {
      if (item.tag == group.selected) {
        selectedType = item.type;
        selectedIsGroup = item.isGroup;
      }
    }
    const readinessTimeout = Duration(seconds: 30);
    final deadline = DateTime.now().add(readinessTimeout);
    OutboundInfo? runtimeLeaf;
    String runtimeOutbound = '';
    do {
      final groups = await coreService.core.backgroundCommandClient
          .outboundsInfo(Empty())
          .first
          .timeout(const Duration(seconds: 8));
      final systemInfo = await coreService.core.backgroundCommandClient
          .getSystemInfo(Empty())
          .timeout(const Duration(seconds: 8));
      runtimeOutbound = systemInfo.currentOutbound;
      runtimeLeaf = resolveRuntimeLeaf(groups, runtimeOutbound);
      if (!selectedIsGroup || runtimeLeaf != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } while (DateTime.now().isBefore(deadline));
    if (selectedIsGroup && runtimeLeaf == null) {
      throw RuntimeFailure.deadline('concrete outbound readiness', readinessTimeout);
    }
    await reporter.event('outbound_selected', {
      'selector_id': await safeId(group.tag),
      'selected_id': await safeId(group.selected),
      'selected_type': selectedType,
      'runtime_outbound_id': await safeId(runtimeOutbound),
      'runtime_leaf_id': runtimeLeaf == null ? null : await safeId(runtimeLeaf.tag),
      'runtime_leaf_type': runtimeLeaf?.type,
    });
  }

  Future<void> _verifyTraffic({bool verifyProductHealth = true}) async {
    for (final target in options.trafficUrls) {
      final stopwatch = Stopwatch()..start();
      int status;
      try {
        status = switch (options.mode) {
          HarnessMode.localProxy => await _fetchWithDartClient(target, proxy: true),
          HarnessMode.tun => await _fetchWithDartClient(target, proxy: false),
          HarnessMode.systemProxy => await _fetchWithSystemProxy(target),
        };
      } catch (error) {
        reporter.trafficResults.add({
          'target': _safeUri(target),
          'route': options.mode.cliName,
          'status': 'FAIL',
          'elapsed_ms': stopwatch.elapsedMilliseconds,
          ..._networkFailureJson(error),
        });
        throw RuntimeFailure.fail('HTTPS traffic failed through ${options.mode.cliName}');
      }
      reporter.trafficResults.add({
        'target': _safeUri(target),
        'route': options.mode.cliName,
        'status': 'PASS',
        'http_status': status,
        'elapsed_ms': stopwatch.elapsedMilliseconds,
      });
    }

    if (verifyProductHealth) await _verifyBackendHealthSignal();
    await reporter.event('traffic_verified', {
      'checks': options.trafficUrls.length + (verifyProductHealth ? 1 : 0),
      'product_health_checked': verifyProductHealth,
    });
  }

  Future<void> _verifyDirectTraffic(int cycle) async {
    for (final target in options.trafficUrls) {
      final stopwatch = Stopwatch()..start();
      try {
        final status = await _fetchWithDartClient(target, proxy: false);
        reporter.trafficResults.add({
          'target': _safeUri(target),
          'route': 'direct-after-disconnect',
          'signal': 'ordinary-internet',
          'status': 'PASS',
          'http_status': status,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
        });
      } catch (error) {
        reporter.trafficResults.add({
          'target': _safeUri(target),
          'route': 'direct-after-disconnect',
          'signal': 'ordinary-internet',
          'status': 'FAIL',
          'elapsed_ms': stopwatch.elapsedMilliseconds,
          ..._networkFailureJson(error),
        });
        throw RuntimeFailure.fail('Direct HTTPS failed after S02 disconnect');
      }
    }
    await reporter.event('s02_direct_internet_verified', {'cycle': cycle, 'checks': options.trafficUrls.length});
  }

  Future<void> _verifyBackendHealthSignal() async {
    final stopwatch = Stopwatch()..start();
    var dnsAddresses = 0;
    try {
      dnsAddresses = (await InternetAddress.lookup(
        options.backendHealthUrl.host,
      ).timeout(const Duration(seconds: 8))).length;
      if (dnsAddresses == 0) throw const SocketException('health target DNS returned no addresses');
      final status = switch (options.mode) {
        HarnessMode.systemProxy => await _fetchWithSystemProxy(options.backendHealthUrl),
        HarnessMode.localProxy => await _fetchWithDartClient(options.backendHealthUrl, proxy: true),
        HarnessMode.tun => await _fetchWithDartClient(options.backendHealthUrl, proxy: false),
      };
      reporter.trafficResults.add({
        'target': _safeUri(options.backendHealthUrl),
        'route': options.mode.cliName,
        'signal': 'product-health',
        'status': 'PASS',
        'http_status': status,
        'dns_address_count': dnsAddresses,
        'elapsed_ms': stopwatch.elapsedMilliseconds,
      });
    } catch (error) {
      reporter.trafficResults.add({
        'target': _safeUri(options.backendHealthUrl),
        'route': options.mode.cliName,
        'signal': 'product-health',
        'status': 'FAIL',
        'dns_address_count': dnsAddresses,
        'proxy_listener_ready': await _proxyListening(),
        'native_core_status': _coreStateJson(coreService.currentState)['status'],
        'elapsed_ms': stopwatch.elapsedMilliseconds,
        ..._networkFailureJson(error),
      });
      throw RuntimeFailure.fail('ZEON domain health failed after deterministic HTTPS controls passed');
    }
  }

  Future<int> _fetchWithDartClient(Uri target, {required bool proxy}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    client.findProxy = (_) => proxy ? 'PROXY 127.0.0.1:${options.proxyPort}' : 'DIRECT';
    try {
      final request = await client
          .getUrl(target)
          .timeout(const Duration(seconds: 15), onTimeout: () => throw TimeoutException('get_url'));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('response_headers'),
      );
      await response.drain<void>().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('response_body'),
      );
      if (response.statusCode != 200) throw StateError('HTTPS response was not 200');
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _fetchWithSystemProxy(Uri target) async {
    const script = r'''
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
try {
  $target=[Uri]$env:ZEON_RUNTIME_TRAFFIC_TARGET
  $expectedPort=[int]$env:ZEON_RUNTIME_PROXY_PORT
  $resolved=[Net.WebRequest]::DefaultWebProxy.GetProxy($target)
  if($null -eq $resolved -or $resolved.Host -notin @('127.0.0.1','localhost') -or $resolved.Port -ne $expectedPort){exit 42}
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $request=[Net.HttpWebRequest]::Create($target)
  $request.Method='GET'
  $request.Proxy=[Net.WebRequest]::DefaultWebProxy
  $request.AllowAutoRedirect=$true
  $request.Timeout=15000
  $request.ReadWriteTimeout=15000
  $response=[Net.HttpWebResponse]$request.GetResponse()
  try {
    $stream=$response.GetResponseStream()
    try {
      $buffer=New-Object byte[] 8192
      while($stream.Read($buffer,0,$buffer.Length) -gt 0){}
    } finally {
      if($null -ne $stream){$stream.Dispose()}
    }
    [Console]::Out.Write([string][int]$response.StatusCode)
  } finally {
    $response.Dispose()
  }
} catch [Net.WebException] { exit 43 }
catch { exit 44 }''';
    final childEnvironment = Map<String, String>.from(Platform.environment)
      ..remove('HTTP_PROXY')
      ..remove('HTTPS_PROXY')
      ..remove('ALL_PROXY')
      ..remove('NO_PROXY')
      ..remove('http_proxy')
      ..remove('https_proxy')
      ..remove('all_proxy')
      ..remove('no_proxy')
      ..['ZEON_RUNTIME_TRAFFIC_TARGET'] = target.toString()
      ..['ZEON_RUNTIME_PROXY_PORT'] = '${options.proxyPort}';
    final process = await Process.start(
      'powershell.exe',
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
      environment: childEnvironment,
      includeParentEnvironment: false,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.drain<void>();
    late final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      process.kill();
      throw TimeoutException('system_proxy_process');
    } finally {
      await stderr.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    final status = int.tryParse((await stdout).trim());
    if (exitCode != 0 || status == null) {
      throw ProcessException('powershell.exe', const [], 'System proxy HTTPS probe failed', exitCode);
    }
    if (status != 200) throw StateError('HTTPS response was not 200');
    return status;
  }

  Map<String, Object?> _networkFailureJson(Object error) => switch (error) {
    WindowsSystemNetworkException() => {
      'error_type': error.runtimeType.toString(),
      'operation': error.operation,
      'stage': error.stage.name,
      'win32_code': error.win32Code,
      'hresult': '0x${error.hresult.toUnsigned(32).toRadixString(16).padLeft(8, '0')}',
      'secure_failures': error.secureFailures,
    },
    TimeoutException() => {'error_type': error.runtimeType.toString(), 'stage': error.message},
    ProcessException() => {
      'error_type': error.runtimeType.toString(),
      'exit_code': error.errorCode,
      'stage': switch (error.errorCode) {
        42 => 'system_proxy_resolution',
        43 => 'system_proxy_web_request',
        44 => 'system_proxy_probe',
        _ => 'system_proxy_process',
      },
    },
    _ => {'error_type': error.runtimeType.toString()},
  };

  Future<bool> _proxyListening() async {
    try {
      final socket = await Socket.connect('127.0.0.1', options.proxyPort, timeout: const Duration(milliseconds: 500));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureProfile() async {
    final existing = await container!.read(activeProfileProvider.future);
    if (existing != null && options.scenario != RuntimeScenario.p03R17) return;
    final fixturePath = options.profileFile;
    if (fixturePath == null) throw RuntimeFailure.environment('Profile fixture file is required');
    final fixture = File(fixturePath);
    if (!await fixture.exists()) throw RuntimeFailure.environment('Profile fixture file does not exist');
    final repository = await container!.read(profileRepositoryProvider.future);
    final imported = options.scenario == RuntimeScenario.p03R17
        ? await repository
              .upsertRemote(_validatedRemoteFixtureSource(await fixture.readAsString()), directOnly: true)
              .run()
        : await repository.addLocal(await fixture.readAsString()).run();
    if (imported.isLeft()) throw RuntimeFailure.environment('Validation profile fixture import failed');
    await _until(
      () {
        final active = container!.read(activeProfileProvider).valueOrNull;
        return options.scenario == RuntimeScenario.p03R17 ? active is RemoteProfileEntity : active != null;
      },
      'active profile fixture',
      const Duration(seconds: 60),
    );
    await reporter.event('validation_profile_imported', {
      'remote': options.scenario == RuntimeScenario.p03R17,
      if (options.scenario == RuntimeScenario.p03R17) 'source_host': 'zeon-vps.link',
    });
  }

  String _validatedRemoteFixtureSource(String fixture) {
    Object? decoded;
    try {
      decoded = jsonDecode(fixture);
    } catch (_) {
      throw RuntimeFailure.environment('Remote profile fixture bundle is malformed');
    }
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 'zeon.runtime-remote-profile-fixture.v1') {
      throw RuntimeFailure.environment('Remote profile fixture bundle schema is invalid');
    }
    final source = Uri.tryParse(decoded['source_url']?.toString() ?? '');
    if (source == null ||
        source.scheme != 'https' ||
        source.host.toLowerCase() != 'zeon-vps.link' ||
        source.userInfo.isNotEmpty ||
        source.hasQuery ||
        source.hasFragment ||
        (source.hasPort && source.port != 443) ||
        source.pathSegments.length != 2 ||
        source.pathSegments.first != 'open' ||
        source.pathSegments.last.isEmpty) {
      throw RuntimeFailure.environment('Remote profile fixture source is outside the approved HTTPS scope');
    }
    return source.toString();
  }

  Future<void> _validateMachine() async {
    if (!Platform.isWindows || !Environment.isPortable || !_runtimeGuard) {
      throw RuntimeFailure.environment('Dedicated portable Windows runtime build is required');
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(_sourceSha) ||
        _buildType != 'windows-runtime-validation' ||
        _buildUtc.isEmpty) {
      throw RuntimeFailure.harness('Runtime build provenance defines are missing');
    }
    final machineName = Platform.environment['COMPUTERNAME']?.toUpperCase() ?? '';
    if (!const {'ZEON-W10-LAB', 'ZEON-RECOVERY', 'ZEON-W11-LAB'}.contains(machineName)) {
      throw RuntimeFailure.environment('Runtime validation requires an allow-listed ZEON lab machine');
    }
    final manufacturer = await Process.run('reg.exe', [
      'query',
      r'HKLM\HARDWARE\DESCRIPTION\System\BIOS',
      '/v',
      'SystemManufacturer',
    ]).timeout(const Duration(seconds: 30));
    if (manufacturer.exitCode != 0) {
      throw RuntimeFailure.environment('Unable to confirm laboratory manufacturer');
    }
    final manufacturerText = (manufacturer.stdout as String).toLowerCase();
    final virtualization = manufacturerText.contains('qemu')
        ? 'qemu'
        : manufacturerText.contains('openstack')
        ? 'openstack'
        : null;
    if (virtualization == null) {
      throw RuntimeFailure.environment('ZEON laboratory manufacturer was not confirmed');
    }
    reporter.machine = machineName;
    await reporter.event('machine_guard_passed', {'machine': machineName, 'virtualization': virtualization});
  }

  Future<void> _networkSnapshot(String label) async {
    final safeLabel = label.replaceAll(RegExp('[^A-Za-z0-9._-]'), '-');
    final path = '${reporter.directory.path}${Platform.pathSeparator}$safeLabel-network.json';
    final commands = <String, List<String>>{
      'routes_ipv4': ['route.exe', 'print', '-4'],
      'routes_ipv6': ['route.exe', 'print', '-6'],
      'interfaces': ['ipconfig.exe', '/all'],
      'tcp_endpoints': ['netstat.exe', '-ano', '-p', 'tcp'],
      for (final name in NetworkBaseline.names)
        'wininet_$name': ['reg.exe', 'query', NetworkBaseline._internetSettings, '/v', name],
      'winhttp': ['netsh.exe', 'winhttp', 'show', 'proxy'],
    };
    final snapshot = <String, Object?>{};
    for (final entry in commands.entries) {
      final result = await Process.run(
        entry.value.first,
        entry.value.skip(1).toList(),
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0 && !(entry.key.startsWith('wininet_') && result.exitCode == 1)) {
        throw RuntimeFailure.harness('Network evidence capture failed: ${entry.key}');
      }
      snapshot[entry.key] = {'exit_code': result.exitCode, 'stdout': result.stdout, 'stderr': result.stderr};
    }
    await File(path).writeAsString('${const JsonEncoder.withIndent('  ').convert(snapshot)}\n', flush: true);
    reporter.addEvidence(path);
    await reporter.event('network_snapshot_saved', {'path': path});
  }

  Future<bool> cleanup({required String label}) async {
    if (reporter.phase != 'cleanup') await reporter.startPhase('cleanup');
    final started = DateTime.now().toUtc();
    final errors = <String>[];
    try {
      if (container != null) {
        try {
          await container!.read(connectionNotifierProvider.notifier).abortConnection().timeout(options.cleanupTimeout);
        } catch (error) {
          errors.add('application_abort:${error.runtimeType}');
        }
        try {
          await coreService.stop(force: true).run().timeout(options.cleanupTimeout);
        } catch (error) {
          errors.add('core_stop:${error.runtimeType}');
        }
        try {
          await _until(
            () => container!.read(connectionNotifierProvider).valueOrNull is Disconnected,
            'cleanup application disconnect',
            options.cleanupTimeout,
          );
        } catch (error) {
          errors.add('application_state:${error.runtimeType}');
        }
        try {
          await _until(
            () => coreService.currentState is CoreStopped,
            'cleanup native core stop',
            options.cleanupTimeout,
          );
        } catch (error) {
          errors.add('native_core_state:${error.runtimeType}');
        }
        try {
          await _until(() async => !await _proxyListening(), 'cleanup proxy listener', options.cleanupTimeout);
        } catch (error) {
          errors.add('proxy_listener:${error.runtimeType}');
        }
        if (originalMode != null) {
          try {
            await container!.read(ConfigOptions.serviceMode.notifier).update(originalMode!);
          } catch (error) {
            errors.add('service_mode_restore:${error.runtimeType}');
          }
        }
        if (originalIPv6Mode != null) {
          try {
            await container!.read(ConfigOptions.ipv6Mode.notifier).update(originalIPv6Mode!);
          } catch (error) {
            errors.add('ipv6_mode_restore:${error.runtimeType}');
          }
        }
        if (originalMixedPort != null) {
          try {
            await container!.read(ConfigOptions.mixedPort.notifier).update(originalMixedPort!);
          } catch (error) {
            errors.add('mixed_port_restore:${error.runtimeType}');
          }
        }
        if (originalProxySelection != null) {
          try {
            final group = await container!
                .read(proxiesOverviewNotifierProvider.future)
                .timeout(const Duration(seconds: 10));
            if (group != null && group.items.any((item) => item.tag == originalProxySelection)) {
              await container!
                  .read(proxiesOverviewNotifierProvider.notifier)
                  .changeProxy(group.tag, originalProxySelection!);
            }
          } catch (error) {
            errors.add('proxy_selection_restore:${error.runtimeType}');
          }
        }
      }
      if (baseline != null) {
        try {
          await baseline!.restore().timeout(options.cleanupTimeout);
        } catch (error) {
          errors.add('network_baseline_restore:${error.runtimeType}');
        }
      }
      if (container != null) {
        reporter.appState = _appStateJson(container!.read(connectionNotifierProvider));
        reporter.nativeState = await _nativeStateJson(coreService);
      }
      try {
        await _networkSnapshot('after-cleanup');
      } catch (error) {
        errors.add('cleanup_evidence:${error.runtimeType}');
      }
    } finally {
      final appDisconnected = reporter.appState['status'] == 'disconnected';
      final coreStopped = reporter.nativeState['status'] == 'stopped';
      final proxyClosed = !await _proxyListening();
      final verified = errors.isEmpty && appDisconnected && coreStopped && proxyClosed;
      reporter.cleanupAttempts.add({
        'label': label,
        'started_utc': started.toIso8601String(),
        'ended_utc': DateTime.now().toUtc().toIso8601String(),
        'verified': verified,
        'errors': errors,
        'application_state': reporter.appState,
        'native_core_state': reporter.nativeState,
        'application_disconnected': appDisconnected,
        'native_core_stopped': coreStopped,
        'proxy_listener_closed': proxyClosed,
      });
      await reporter.event('cleanup_completed', {'verified': verified, 'errors': errors});
      await reporter.endPhase(status: verified ? 'passed' : 'failed');
    }
    return reporter.cleanupAttempts.last['verified'] == true;
  }
}

Map<String, Object?> _appStateJson(AsyncValue<ConnectionStatus> state) => switch (state) {
  AsyncData(value: final value) => {
    'async': 'data',
    'status': switch (value) {
      Disconnected() => 'disconnected',
      Connecting() => 'connecting',
      Connected() => 'connected',
      Disconnecting() => 'disconnecting',
    },
  },
  AsyncLoading() => const {'async': 'loading'},
  AsyncError(error: final error) => {'async': 'error', 'error_type': error.runtimeType.toString()},
  _ => const {'async': 'unknown'},
};

Map<String, Object?> _coreStateJson(CoreStatus state) => {
  'status': switch (state) {
    CoreStopped() => 'stopped',
    CoreStarting() => 'starting',
    CoreStarted() => 'started',
    CoreStopping() => 'stopping',
  },
};

Future<Map<String, Object?>> _nativeStateJson(ZeonCoreService service) async {
  final result = <String, Object?>{..._coreStateJson(service.currentState)};
  try {
    final info = await service.core.backgroundCommandClient.getSystemInfo(Empty()).timeout(const Duration(seconds: 5));
    result.addAll({
      'current_outbound_id': await safeId(info.currentOutbound),
      'memory_bytes': info.memory.toInt(),
      'goroutines': info.goroutines,
      'connections_out': info.connectionsOut,
    });
  } catch (error) {
    result['diagnostic_error_type'] = error.runtimeType.toString();
  }
  return result;
}

Future<void> _until(FutureOr<bool> Function() predicate, String name, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw RuntimeFailure.deadline(name, timeout);
}

Future<void> main(List<String> args) async {
  HarnessReporter? reporter;
  RuntimeHarness? harness;
  var verdict = RuntimeVerdict.harnessError;
  var reason = 'runtime initialization failed';
  try {
    final options = RuntimeOptions.parse(args);
    final directory = Directory(options.evidenceDirectory);
    await directory.create(recursive: true);
    reporter = HarnessReporter(options, directory);
    reporter.addEvidence(reporter.eventsFile.path);
    reporter.addEvidence(reporter.resultFile.path);
    await reporter.event('runtime_started');
    harness = RuntimeHarness(options, reporter);
    await harness.initialize();
    await harness.run();
    verdict = RuntimeVerdict.pass;
    reason = 'Scenario and cleanup completed successfully';
  } on RuntimeFailure catch (error) {
    verdict = error.verdict;
    reason = error.reason;
    await reporter?.event('runtime_failed', {
      'verdict': error.verdict.wireName,
      'reason': error.reason,
      if (error.timeoutKind != null) 'timeout_kind': error.timeoutKind,
      if (error.timeoutSeconds != null) 'timeout_seconds': error.timeoutSeconds,
    });
  } on FormatException catch (error) {
    verdict = RuntimeVerdict.harnessError;
    reason = error.message;
  } catch (error) {
    verdict = RuntimeVerdict.harnessError;
    reason = 'Unexpected harness error: ${error.runtimeType}';
    await reporter?.event('runtime_failed', {'verdict': verdict.wireName, 'error_type': error.runtimeType.toString()});
  } finally {
    if (harness != null && reporter != null) {
      final alreadyClean = reporter.cleanupAttempts.isNotEmpty && reporter.cleanupAttempts.last['verified'] == true;
      if (!alreadyClean) {
        final cleanupOk = await harness.cleanup(label: 'main-finally');
        if (!cleanupOk && verdict == RuntimeVerdict.pass) {
          verdict = RuntimeVerdict.fail;
          reason = 'Cleanup verification failed';
        }
      }
      await reporter.event('process_exit_prepared', {
        'strict_cleanup_verified':
            reporter.cleanupAttempts.isNotEmpty && reporter.cleanupAttempts.last['verified'] == true,
        'provider_teardown': 'process_exit',
      });
      await reporter.sealEvents();
    }
    if (reporter != null) {
      reporter.verdict = verdict;
      reporter.reason = reason;
      await reporter.writeResult();
    } else {
      stderr.writeln(reason);
    }
  }
  exit(verdict.exitCode);
}
