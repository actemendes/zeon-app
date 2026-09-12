// Dedicated finite validation executable, never a production entrypoint.
// Build only through `scripts/build.ps1 -Action windows-runtime`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/bootstrap.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/log/model/log_level.dart' as app_log;
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

import 'runtime_core_snapshot.dart' show resolveRuntimeLeaf, safeId;

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
  autoProxy('auto-proxy');

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
      RuntimeScenario.manualProxy || RuntimeScenario.autoProxy => 600,
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
      evidenceDirectory: evidenceDirectory,
      profileFile: profileFile,
      runId: runId,
      connectTimeout: Duration(seconds: connectSeconds),
      bootstrapTimeout: Duration(seconds: bootstrapSeconds),
      cleanupTimeout: Duration(seconds: cleanupSeconds),
      scenarioTimeout: Duration(seconds: scenarioSeconds),
      trafficUrls: trafficUrls,
      backendHealthUrl: backendHealthUrl,
      s02Cycles: integer('s02-cycles', 'ZEON_RUNTIME_S02_CYCLES', 10, 2, 100),
      proxyPort: integer('proxy-port', 'ZEON_RUNTIME_PROXY_PORT', _defaultProxyPort, 1024, 65535),
      cancelPhase: cancelPhase,
      manualProxyTag: one('manual-proxy-tag', 'ZEON_RUNTIME_MANUAL_PROXY_TAG'),
    );
  }

  Map<String, Object?> toJson() => {
    'scenario': scenario.cliName,
    'mode': mode.cliName,
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
    await _verifyTraffic();
    await _disconnectAndVerify('connect-scenario');
  }

  Future<void> _scenarioS02() async {
    for (var cycle = 1; cycle <= options.s02Cycles; cycle++) {
      await reporter.event('s02_cycle_started', {'cycle': cycle, 'total': options.s02Cycles});
      await _connectAndProveReady();
      await _verifyTraffic();
      await _disconnectAndVerify('s02-cycle-$cycle');
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
          !const {'urltest', 'direct', 'block', 'dns', 'balancer'}.contains(item.type),
      orElse: () => throw RuntimeFailure.environment('No manual proxy is available before Auto transition'),
    );
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, manual.tag);
    await _disconnectAndVerify('auto-proxy-manual-stage');
    await container!.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, auto.tag);
    await _connectAndProveReady();
    await _verifyTraffic();
    final groups = await coreService.core.backgroundCommandClient
        .outboundsInfo(Empty())
        .first
        .timeout(const Duration(seconds: 8));
    final currentGroup = groups.items.firstWhere(
      (item) => item.tag == group.tag,
      orElse: () => throw RuntimeFailure.fail('Native selector group disappeared after Auto reconnect'),
    );
    if (currentGroup.selected != auto.tag) {
      throw RuntimeFailure.fail('Automatic selection was not applied by native runtime');
    }
    final systemInfo = await coreService.core.backgroundCommandClient
        .getSystemInfo(Empty())
        .timeout(const Duration(seconds: 8));
    final leaf = resolveRuntimeLeaf(groups, systemInfo.currentOutbound);
    if (leaf == null) throw RuntimeFailure.fail('Auto selection has no concrete native outbound');
    await reporter.event('auto_proxy_verified', {
      'selector_id': await safeId(auto.tag),
      'runtime_outbound_id': await safeId(leaf.tag),
    });
    await _disconnectAndVerify('auto-proxy');
  }

  Future<void> _prepareMode() async {
    await container!.read(ConfigOptions.serviceMode.notifier).update(options.mode.serviceMode);
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

  Future<void> _verifyTraffic() async {
    for (final target in options.trafficUrls) {
      final stopwatch = Stopwatch()..start();
      int status;
      try {
        status = switch (options.mode) {
          HarnessMode.localProxy => await _fetchWithDartClient(target, proxy: true),
          HarnessMode.tun => await _fetchWithDartClient(target, proxy: false),
          HarnessMode.systemProxy => await _fetchWithWinHttp(target),
        };
      } catch (error) {
        reporter.trafficResults.add({
          'target': _safeUri(target),
          'route': options.mode.cliName,
          'status': 'FAIL',
          'elapsed_ms': stopwatch.elapsedMilliseconds,
          'error_type': error.runtimeType.toString(),
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

    final backendStopwatch = Stopwatch()..start();
    try {
      final response = await container!.read(httpClientProvider).get<dynamic>(options.backendHealthUrl.toString());
      if (response.statusCode != 200) throw StateError('unexpected backend status');
      reporter.trafficResults.add({
        'target': _safeUri(options.backendHealthUrl),
        'route': 'application-http-client',
        'status': 'PASS',
        'http_status': response.statusCode,
        'elapsed_ms': backendStopwatch.elapsedMilliseconds,
      });
    } catch (error) {
      reporter.trafficResults.add({
        'target': _safeUri(options.backendHealthUrl),
        'route': 'application-http-client',
        'status': 'FAIL',
        'elapsed_ms': backendStopwatch.elapsedMilliseconds,
        'error_type': error.runtimeType.toString(),
      });
      throw RuntimeFailure.fail('ZEON domain health failed through the application client');
    }
    await reporter.event('traffic_verified', {'checks': options.trafficUrls.length + 1});
  }

  Future<int> _fetchWithDartClient(Uri target, {required bool proxy}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    client.findProxy = (_) => proxy ? 'PROXY 127.0.0.1:${options.proxyPort}' : 'DIRECT';
    try {
      final response = await (await client.getUrl(target)).close().timeout(const Duration(seconds: 15));
      await response.drain<void>().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw StateError('HTTPS response was not 200');
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _fetchWithWinHttp(Uri target) async {
    final transport = createWindowsSystemHttpTransport();
    if (transport == null) throw StateError('WinHTTP transport is unavailable');
    final response = await transport.send(
      WindowsSystemHttpRequest(
        method: 'GET',
        url: target.toString(),
        headers: const {},
        timeout: const Duration(seconds: 15),
      ),
    );
    if (response.statusCode != 200) throw StateError('WinHTTP response was not 200');
    return response.statusCode;
  }

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
    if (existing != null) return;
    final fixturePath = options.profileFile;
    if (fixturePath == null) throw RuntimeFailure.environment('Profile fixture file is required');
    final fixture = File(fixturePath);
    if (!await fixture.exists()) throw RuntimeFailure.environment('Profile fixture file does not exist');
    final repository = await container!.read(profileRepositoryProvider.future);
    final imported = await repository.addLocal(await fixture.readAsString()).run();
    if (imported.isLeft()) throw RuntimeFailure.environment('Validation profile fixture import failed');
    await _until(
      () => container!.read(activeProfileProvider).valueOrNull != null,
      'active profile fixture',
      const Duration(seconds: 60),
    );
    await reporter.event('validation_profile_imported');
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
      'memory_bytes': info.memory,
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
