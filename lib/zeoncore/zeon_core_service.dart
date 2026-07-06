import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart';
import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart' as loggyl;
import 'package:path/path.dart' as p;
import 'package:protobuf/protobuf.dart';
import 'package:rxdart/rxdart.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/features/connection/model/connection_failure.dart';
import 'package:zeon/features/log/model/log_level.dart' as config_log_level;
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/singbox/model/warp_account.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:zeon/utils/windows_privilege_utils.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_wrapper_stub.dart'
    if (dart.library.io) 'package:zeon/zeoncore/core_interface/core_interface_wrapper.dart';
import 'package:zeon/zeoncore/generated/v2/config/route_rule.pb.dart' as route_rule;
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/init_signal.dart';

enum _CoreLifecycleState { stopped, starting, started, stopping }

class ZeonCoreService with InfraLogger {
  ZeonCoreService(this.ref);
  final Ref ref;
  static const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");
  static const _debugNetworkProfile = String.fromEnvironment("debug_network_profile");
  static const _debugNetworkMtuMode = String.fromEnvironment("debug_network_mtu_mode");
  static const _debugFragmentMode = String.fromEnvironment("debug_fragment_mode");
  static const _debugProfileDnsStrategy = String.fromEnvironment("debug_profile_dns_strategy");
  static const _debugTunImplementation = String.fromEnvironment("debug_tun_implementation");
  static const _debugUdpProbeEnabled = bool.fromEnvironment("debug_udp_probe_enabled");
  static const _debugUdpProbeEndpoint = String.fromEnvironment("debug_udp_probe_endpoint");
  static const _debugUdpProbeSecret = String.fromEnvironment("debug_udp_probe_secret");
  static const _debugUdpProbeCount = int.fromEnvironment("debug_udp_probe_count", defaultValue: 10);
  static const _debugUdpProbeSize = int.fromEnvironment("debug_udp_probe_size", defaultValue: 160);
  static const _debugUdpProbeIntervalMs = int.fromEnvironment("debug_udp_probe_interval_ms", defaultValue: 40);
  static const _debugUdpProbeTimeoutMs = int.fromEnvironment("debug_udp_probe_timeout_ms", defaultValue: 1000);
  static const _debugUdpProbeCooldownSec = int.fromEnvironment("debug_udp_probe_cooldown_sec", defaultValue: 60);
  static const _debugUdpProbeTopN = int.fromEnvironment("debug_udp_probe_top_n", defaultValue: 3);
  static const _listenerBackoffBaseMs = 300;
  static const _listenerBackoffMaxMs = 6000;

  bool get _useMockCore => kIsWeb && kDebugMode && _debugSeedProfileEnabled;

  // CoreZeonCoreService() {}
  final core = getCoreInterface();

  CoreStatus currentState = const CoreStatus.stopped();
  final statusController = BehaviorSubject<CoreStatus>();
  final logController = BehaviorSubject<List<LogMessage>>();
  final CallOptions? grpcOptions = null; //CallOptions(timeout: const Duration(milliseconds: 10000));
  final Map<String, StreamSubscription?> subscriptions = {};
  final Map<String, int> _listenerReconnectAttempt = {};
  final Map<String, Future<void>> _statusListenerRecoveryByKey = {};
  int _stoppingStatusWatchdogGeneration = 0;
  Future<void> _lifecycleQueueTail = Future<void>.value();
  _CoreLifecycleState _lifecycleState = _CoreLifecycleState.stopped;
  ChangeHiddifySettingsRequest? _latestCoreOptionsRequest;
  static const _platformChannel = MethodChannel("com.zeon.app/platform");
  List<OutboundGroup> latest = [];
  final BehaviorSubject<List<OutboundGroup>> _mockGroupsController = BehaviorSubject<List<OutboundGroup>>();

  void _ensureMockGroups() {
    if (!_useMockCore || _mockGroupsController.hasValue) return;

    latest = [
      OutboundGroup(
        tag: "select",
        type: "Selector",
        selected: "de-frankfurt-1",
        selectable: true,
        isExpand: false,
        items: [
          OutboundInfo(
            tag: "de-frankfurt-1",
            tagDisplay: "Germany - Frankfurt 1",
            type: "VLESS",
            isSelected: true,
            isVisible: true,
            isSecure: true,
            host: "de1.zeon.dev",
            port: 443,
            urlTestDelay: 29,
            success: true,
            errorType: "none",
            healthScore: 100,
            ipinfo: IpInfo(ip: "91.107.233.10", countryCode: "DE", city: "Frankfurt", org: "Hetzner Online GmbH"),
          ),
          OutboundInfo(
            tag: "nl-amsterdam-1",
            tagDisplay: "Netherlands - Amsterdam 1",
            type: "VLESS",
            isSelected: false,
            isVisible: true,
            isSecure: true,
            host: "nl1.zeon.dev",
            port: 443,
            urlTestDelay: 90,
            success: true,
            errorType: "none",
            healthScore: 82,
            ipinfo: IpInfo(ip: "95.211.44.52", countryCode: "NL", city: "Amsterdam", org: "LeaseWeb Netherlands B.V."),
          ),
          OutboundInfo(
            tag: "us-newyork-1",
            tagDisplay: "USA - New York 1",
            type: "Trojan",
            isSelected: false,
            isVisible: true,
            isSecure: true,
            host: "us1.zeon.dev",
            port: 443,
            urlTestDelay: 180,
            success: true,
            errorType: "none",
            healthScore: 60,
            ipinfo: IpInfo(ip: "198.74.58.101", countryCode: "US", city: "New York", org: "Akamai Connected Cloud"),
          ),
          OutboundInfo(
            tag: "jp-tokyo-1",
            tagDisplay: "Japan - Tokyo 1",
            type: "VLESS",
            isSelected: false,
            isVisible: true,
            isSecure: true,
            host: "jp1.zeon.dev",
            port: 443,
            urlTestDelay: 650,
            success: true,
            errorType: "none",
            healthScore: 40,
            ipinfo: IpInfo(ip: "139.162.65.37", countryCode: "JP", city: "Tokyo", org: "Akamai Connected Cloud"),
          ),
          OutboundInfo(
            tag: "br-penalized-1",
            tagDisplay: "Brazil - Penalized",
            type: "Trojan",
            isSelected: false,
            isVisible: true,
            isSecure: true,
            host: "br1.zeon.dev",
            port: 443,
            urlTestDelay: 42,
            success: true,
            errorType: "none",
            healthScore: 20,
            ipinfo: IpInfo(ip: "45.79.1.20", countryCode: "BR", city: "Sao Paulo", org: "Akamai Connected Cloud"),
          ),
          OutboundInfo(
            tag: "failed-1",
            tagDisplay: "Failed Probe",
            type: "VLESS",
            isSelected: false,
            isVisible: true,
            isSecure: true,
            host: "bad.zeon.dev",
            port: 443,
            urlTestDelay: 65535,
            success: false,
            errorType: "timeout",
            healthScore: 0,
            ipinfo: IpInfo(ip: "203.0.113.10", countryCode: "ZZ", city: "Unknown", org: "Example"),
          ),
        ],
      ),
    ];
    _mockGroupsController.add(_cloneGroups(latest));
  }

  List<OutboundGroup> _cloneGroups(List<OutboundGroup> groups) =>
      groups.map((group) => OutboundGroup()..mergeFromMessage(group)).toList();

  void _rememberOutboundGroups(Iterable<OutboundGroup> groups, String source) {
    final snapshot = _cloneGroups(groups.toList());
    if (snapshot.isEmpty) return;
    latest = snapshot;
    loggy.debug("cached outbound snapshot from $source: groups=${snapshot.length}");
  }

  OutboundGroup? _firstOutboundGroupSnapshot() {
    if (latest.isEmpty) return null;
    return OutboundGroup()..mergeFromMessage(latest.first);
  }

  List<OutboundGroup> _outboundGroupsSnapshot() => _cloneGroups(latest);

  void _emitMockGroups({bool deferred = false}) {
    if (!_useMockCore) return;
    final payload = _cloneGroups(latest);
    if (deferred) {
      Future<void>.microtask(() {
        if (!_mockGroupsController.isClosed) {
          _mockGroupsController.add(payload);
        }
      });
      return;
    }
    _mockGroupsController.add(payload);
  }

  void _clearRuntimeOutboundSnapshot(String reason) {
    if (_useMockCore || latest.isEmpty) return;
    loggy.debug("clearing outbound snapshot: $reason");
    latest = [];
  }

  void _transitionLifecycle(_CoreLifecycleState next, {String reason = ""}) {
    final prev = _lifecycleState;
    if (prev == next) return;
    _lifecycleState = next;
    loggy.info("lifecycle: ${prev.name} -> ${next.name}${reason.isEmpty ? "" : " ($reason)"}");
  }

  void _syncLifecycleFromCoreStatus(CoreStatus status, {String reason = "status event"}) {
    switch (status) {
      case CoreStarting():
        _transitionLifecycle(_CoreLifecycleState.starting, reason: reason);
      case CoreStarted():
        _transitionLifecycle(_CoreLifecycleState.started, reason: reason);
      case CoreStopping():
        _transitionLifecycle(_CoreLifecycleState.stopping, reason: reason);
      case CoreStopped():
        _transitionLifecycle(_CoreLifecycleState.stopped, reason: reason);
    }
  }

  Future<CoreStatus> _applyCoreStatusFromListener(String key, CoreStatus next) async {
    // Guard against transient/stale "stopped" events while background core is still alive.
    if (next is CoreStopped && _lifecycleState == _CoreLifecycleState.started) {
      try {
        if (await core.isActiveBg()) {
          loggy.warning("ignore stale stopped from coreInfoListener[$key]: bg port still active");
          return currentState;
        }
      } catch (_) {}
    }
    currentState = next;
    _syncLifecycleFromCoreStatus(currentState, reason: "coreInfoListener[$key]");
    statusController.add(currentState);
    if (next is CoreStopping) {
      _scheduleStoppingStatusWatchdog("coreInfoListener[$key]");
    }
    return currentState;
  }

  Future<T> _enqueueLifecycle<T>(String opName, Future<T> Function() action) {
    final completer = Completer<T>();
    loggy.debug("lifecycle queue: enqueue $opName (state=${_lifecycleState.name})");
    _lifecycleQueueTail = _lifecycleQueueTail.catchError((_) {}).then((_) async {
      loggy.debug("lifecycle queue: begin $opName (state=${_lifecycleState.name})");
      try {
        final res = await action();
        if (!completer.isCompleted) completer.complete(res);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      } finally {
        loggy.debug("lifecycle queue: end $opName (state=${_lifecycleState.name})");
      }
    });
    return completer.future;
  }

  Duration _listenerReconnectDelay(String key) {
    final attempt = (_listenerReconnectAttempt[key] ?? 0) + 1;
    _listenerReconnectAttempt[key] = attempt;
    final exp = min(_listenerBackoffMaxMs, _listenerBackoffBaseMs * (1 << min(attempt - 1, 4)));
    final jitter = Random().nextInt(max(1, exp ~/ 4));
    return Duration(milliseconds: exp + jitter);
  }

  void _scheduleListenerReconnect(String key, Future<void> Function() starter) {
    if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) {
      loggy.debug("listener reconnect skipped [$key]: lifecycle=${_lifecycleState.name}");
      return;
    }
    final delay = _listenerReconnectDelay(key);
    loggy.debug("listener reconnect scheduled [$key] in ${delay.inMilliseconds}ms");
    Future<void>.delayed(delay, () async {
      if (!core.isInitialized()) return;
      if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) return;
      if (subscriptions.containsKey(key)) return;
      try {
        await starter();
      } catch (e, st) {
        loggy.warning("listener reconnect failed [$key]", e, st);
      }
    });
  }

  void _recoverStatusAfterListenerClose(String key, Object? error) {
    final stateNeedsRecovery = _lifecycleState == _CoreLifecycleState.stopping || currentState is CoreStopping;
    if (!stateNeedsRecovery || _useMockCore) return;

    final recovery = _statusListenerRecoveryByKey.putIfAbsent(key, () async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _recoverStuckStoppingStatus("status listener recovery", error, listenerKey: key);
    });

    unawaited(
      recovery.whenComplete(() {
        if (identical(_statusListenerRecoveryByKey[key], recovery)) {
          _statusListenerRecoveryByKey.remove(key);
        }
      }),
    );
  }

  void _scheduleStoppingStatusWatchdog(String reason) {
    final generation = ++_stoppingStatusWatchdogGeneration;
    unawaited(
      Future<void>.delayed(const Duration(seconds: 10), () async {
        if (generation != _stoppingStatusWatchdogGeneration) return;
        await _recoverStuckStoppingStatus("stopping watchdog/$reason", null);
      }),
    );
  }

  Future<void> _recoverStuckStoppingStatus(String reason, Object? error, {String? listenerKey}) async {
    final stillNeedsRecovery = _lifecycleState == _CoreLifecycleState.stopping || currentState is CoreStopping;
    if (!stillNeedsRecovery || _useMockCore) return;

    final bgReachable = await _isBackgroundCoreReachable();
    if (!bgReachable) {
      loggy.warning("$reason: background core is down, forcing stopped", error);
      await _deleteCoreCurrentConfigSnapshot();
      _transitionLifecycle(_CoreLifecycleState.stopped, reason: reason);
      _clearRuntimeOutboundSnapshot(reason);
      statusController.add(currentState = const CoreStatus.stopped());
      return;
    }

    loggy.warning("$reason: background core is still active, forcing started", error);
    _transitionLifecycle(_CoreLifecycleState.started, reason: reason);
    statusController.add(currentState = const CoreStatus.started());
    if (listenerKey != null && core.isInitialized()) {
      try {
        await startListeningStatus(listenerKey, listenerKey == "bg" ? core.bgClient : core.fgClient);
      } catch (e, st) {
        loggy.warning("failed to restart status listener after recovery [$listenerKey]", e, st);
      }
    }
  }

  Future<void> init() async {
    await _deleteCoreCurrentConfigSnapshot();
    await setup()
        .mapLeft((e) {
          loggy.error(e);
          if (PlatformUtils.isIOS) return;
          statusController.add(const CoreStatus.stopped());
          ref.read(inAppNotificationControllerProvider).showErrorToast(e);
        })
        .map((_) {
          loggy.info("ZEON-core setup done");
          if (!_useMockCore) {
            ref.read(coreRestartSignalProvider.notifier).restart();
          }
        })
        .run();
  }

  /// validates config by path and save it
  ///
  /// [path] is used to save validated config
  /// [tempPath] includes base config, possibly invalid
  /// [debug] indicates if debug mode (avoid in prod)

  TaskEither<String, Unit> validateConfigByPath(String path, String tempPath, bool debug) {
    return TaskEither(() async {
      if (_useMockCore) {
        return right(unit);
      }
      const maxAttempts = 3;
      Object? lastError;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          final client = await _clientForForegroundOperation("validate config");
          final response = await client.parse(ParseRequest(tempPath: tempPath, configPath: path, debug: false));
          if (response.responseCode == ResponseCode.OK) {
            return right(unit);
          }
          return left("${response.responseCode} ${response.message}");
        } catch (e, st) {
          lastError = e;
          loggy.warning("validate config attempt [$attempt/$maxAttempts] failed", e, st);
          if (attempt == maxAttempts) break;
          await setup().run();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      return left("validate config grpc unavailable: $lastError");
    });
  }

  TaskEither<String, String> generateFullConfigByPath(String path) {
    return TaskEither(() async {
      if (_useMockCore) {
        return right("{}");
      }
      final client = await _clientForForegroundOperation("generate full config");
      final response = await client.parse(ParseRequest(configPath: path, debug: false));
      if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      return right(response.content);
    });
  }

  TaskEither<String, String> generateFullConfig(String content) {
    return TaskEither(() async {
      if (_useMockCore) {
        return right("{}");
      }
      final response = await core.fgClient.parse(ParseRequest(content: content, debug: false));
      if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      return right(response.content);
    });
  }

  TaskEither<String, String> validateConfigContent(String content, bool debug) {
    return TaskEither(() async {
      if (_useMockCore) {
        return right(content);
      }
      const maxAttempts = 3;
      Object? lastError;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          final client = await _clientForForegroundOperation("validate config content");
          final response = await client.parse(ParseRequest(content: content, debug: debug));
          if (response.responseCode == ResponseCode.OK) {
            return right(response.content);
          }
          return left("${response.responseCode} ${response.message}");
        } catch (e, st) {
          lastError = e;
          loggy.warning("validate config content attempt [$attempt/$maxAttempts] failed", e, st);
          if (attempt == maxAttempts) break;
          await setup().run();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      return left("validate config grpc unavailable: $lastError");
    });
  }

  TaskEither<String, Unit> setup() {
    return TaskEither(() async {
      if (_useMockCore) {
        currentState = const CoreStatus.stopped();
        _transitionLifecycle(_CoreLifecycleState.stopped, reason: "mock setup");
        statusController.add(currentState);
        return right(unit);
      }
      try {
        await _deleteCoreCurrentConfigSnapshot();
        final directories = ref.read(appDirectoriesProvider).requireValue;
        // In Flutter debug builds we need the core platform log bridge enabled
        // even when the user-facing debug setting is off. The hcore bridge still
        // exposes only warning+ logs by default, with selected Smart Active
        // diagnostics promoted explicitly on the Go side.
        final debug = ref.read(debugModeNotifierProvider) || kDebugMode;
        final setupResponse = await core.setup(directories, debug, 3);

        if (setupResponse.isNotEmpty) {
          return left(setupResponse);
        }

        await startListeningLogs("fg", core.fgClient);
        // await startListeningStatus("fg", core.fgClient);
        final bgActive = core.isSingleChannel() || await core.isActiveBg();
        if (bgActive && !core.isSingleChannel()) {
          await startListeningLogs("bg", core.bgClient);
        }
        if (!core.isSingleChannel()) {
          try {
            currentState = bgActive ? const CoreStatus.started() : const CoreStatus.stopped();
            _transitionLifecycle(
              bgActive ? _CoreLifecycleState.started : _CoreLifecycleState.stopped,
              reason: "setup background probe",
            );
          } catch (e) {
            loggy.warning("failed to detect background core state: $e");
          }
        }
        statusController.add(currentState);
        if (bgActive) {
          await startListeningStatus("bg", core.bgClient);
        }
        // ref.read(coreRestartSignalProvider.notifier).restart();
        return right(unit);
      } catch (e) {
        return left(e.toString());
      }
    });
  }

  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) {
    return TaskEither(() async {
      if (_useMockCore) {
        return right(unit);
      }
      loggy.debug("changing options");
      // latestOptions = options;
      final payload = await _buildCoreOptionsPayload(options);
      loggy.info("core payload (safe): ${_safeCorePayload(payload)}");
      final request = ChangeHiddifySettingsRequest(hiddifySettingsJson: jsonEncode(payload));
      _latestCoreOptionsRequest = request;
      const maxAttempts = 3;
      Object? lastTransientError;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          final client = await _clientForForegroundOperation("change options");
          final res = await client.ChangeHiddifySettings(request);
          if (res.messageType != MessageType.EMPTY) {
            return left("${res.messageType} ${res.message}");
          }
          try {
            await core.bgClient.ChangeHiddifySettings(request);
          } on GrpcError catch (e) {
            if (e.code == StatusCode.unavailable || _isTransientGrpcTransportClose(e)) {
              loggy.debug("background core is not started yet! $e");
            } else {
              rethrow;
            }
          }
          return right(unit);
        } on GrpcError catch (e, st) {
          if (!_isTransientGrpcFailure(e)) {
            rethrow;
          }
          lastTransientError = e;
          loggy.warning("change options grpc unavailable [$attempt/$maxAttempts]", e, st);
          await setup().run();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }

      if (core.isInitialized() && !core.isSingleChannel()) {
        try {
          if (await core.isActiveBg()) {
            return await _applyCoreOptionsToClient(request, core.bgClient, "background");
          }
        } catch (e, st) {
          if (!_isTransientCoreFailure(e)) rethrow;
          lastTransientError = e;
          loggy.warning("change options background fallback unavailable", e, st);
        }
      }

      loggy.warning(
        "core options deferred until background core is available",
        lastTransientError ?? "foreground core unavailable",
      );
      return right(unit);
    });
  }

  Future<Either<String, Unit>> _applyLatestCoreOptionsToBackground(String reason) async {
    final request = _latestCoreOptionsRequest;
    if (request == null || _useMockCore) return right(unit);
    return _applyCoreOptionsToClient(request, core.bgClient, "background/$reason");
  }

  Future<Either<String, Unit>> _applyCoreOptionsToClient(
    ChangeHiddifySettingsRequest request,
    CoreClient client,
    String target,
  ) async {
    const maxAttempts = 3;
    Object? lastTransientError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final res = await client.ChangeHiddifySettings(request);
        if (res.messageType != MessageType.EMPTY) {
          return left("${res.messageType} ${res.message}");
        }
        loggy.debug("core options applied to $target");
        return right(unit);
      } on GrpcError catch (e, st) {
        if (!_isTransientGrpcFailure(e)) {
          rethrow;
        }
        lastTransientError = e;
        loggy.warning("apply core options to $target failed [$attempt/$maxAttempts]", e, st);
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 180 * attempt));
        }
      }
    }
    return left("core unavailable while applying options to $target: $lastTransientError");
  }

  Future<CoreClient> _clientForForegroundOperation(String operation) async {
    try {
      if (await core.isActiveFg()) {
        return core.fgClient;
      }
    } catch (e) {
      loggy.debug("$operation: failed checking foreground core", e);
    }

    try {
      await setup().run();
      if (await core.isActiveFg()) {
        return core.fgClient;
      }
    } catch (e) {
      loggy.debug("$operation: foreground setup retry failed", e);
    }

    if (core.isInitialized() && !core.isSingleChannel()) {
      try {
        if (await core.isActiveBg()) {
          loggy.warning("$operation: foreground core unavailable, using background core");
          return core.bgClient;
        }
      } catch (e) {
        loggy.debug("$operation: failed checking background core", e);
      }
    }

    return core.fgClient;
  }

  Future<bool> _ensureCoreInitializedForStream(String operation) async {
    if (core.isInitialized()) return true;

    final result = await setup().run();
    return result.match((err) {
      loggy.warning("$operation: setup before stream failed: $err");
      return false;
    }, (_) => core.isInitialized());
  }

  Future<bool> _isBackgroundCoreReachable() async {
    if (!core.isInitialized()) return false;
    if (core.isSingleChannel()) return true;
    try {
      return await core.isActiveBg();
    } catch (e) {
      loggy.debug("failed checking background core after transient grpc close", e);
      return false;
    }
  }

  bool _isTransientGrpcTransportClose(GrpcError error) {
    final message = (error.message ?? error.toString()).toLowerCase();
    return error.code == StatusCode.unknown &&
        (message.contains("http/2") ||
            message.contains("connection error") ||
            message.contains("transport is closing") ||
            message.contains("stream terminated"));
  }

  bool _isTransientGrpcFailure(GrpcError error) {
    return error.code == StatusCode.unavailable || _isTransientGrpcTransportClose(error);
  }

  bool _isTransientCoreFailure(Object error) {
    if (error is GrpcError) return _isTransientGrpcFailure(error);
    final message = error.toString().toLowerCase();
    return message.contains("core unavailable") ||
        message.contains("grpc") ||
        message.contains("connection refused") ||
        message.contains("http/2") ||
        message.contains("transport is closing") ||
        message.contains("stream terminated") ||
        message.contains("socketexception");
  }

  Future<Map<String, dynamic>> _buildCoreOptionsPayload(SingboxConfigOption options) async {
    final map = Map<String, dynamic>.from(options.toCoreJson());
    final fullConfig = switch (map["enable-full-config"] ?? map["execute-config-as-is"] ?? false) {
      final bool v => v,
      _ => false,
    };
    map["enable-full-config"] = fullConfig;
    map["execute-config-as-is"] = fullConfig;

    if (_debugNetworkProfile.isNotEmpty) {
      map["network-profile"] = _debugNetworkProfile;
    }
    if (_debugNetworkMtuMode.isNotEmpty) {
      map["network-mtu-mode"] = _debugNetworkMtuMode;
    }
    if (_debugFragmentMode.isNotEmpty) {
      map["fragment-mode"] = _debugFragmentMode;
    }
    if (_debugProfileDnsStrategy.isNotEmpty) {
      map["profile-dns-strategy"] = _debugProfileDnsStrategy;
    }
    if (_debugTunImplementation.isNotEmpty) {
      map["tun-implementation"] = _debugTunImplementation;
    }
    if (PlatformUtils.isApple) {
      map["tun-implementation"] = TunImplementation.gvisor.name;
      map["ipv6-mode"] = IPv6Mode.disable.key;
      map["remote-dns-domain-strategy"] = DomainStrategy.ipv4Only.key;
      map["direct-dns-domain-strategy"] = DomainStrategy.ipv4Only.key;
      map["block-quic"] = true;
    }
    if (_debugUdpProbeEnabled) {
      if (_debugUdpProbeSecret.isEmpty) {
        map["udp-probe-enabled"] = false;
        loggy.warning("debug UDP probe requested without secret; keeping probe disabled");
      } else {
        map["udp-probe-enabled"] = true;
        map["udp-probe-endpoint"] = _debugUdpProbeEndpoint.isNotEmpty
            ? _debugUdpProbeEndpoint
            : "udp-probe.zeon-vps.link:8443";
        map["udp-probe-secret"] = _debugUdpProbeSecret;
        map["udp-probe-count"] = _debugUdpProbeCount;
        map["udp-probe-size"] = _debugUdpProbeSize;
        map["udp-probe-interval-ms"] = _debugUdpProbeIntervalMs;
        map["udp-probe-timeout-ms"] = _debugUdpProbeTimeoutMs;
        map["udp-probe-cooldown-sec"] = _debugUdpProbeCooldownSec;
        map["udp-probe-top-n"] = _debugUdpProbeTopN;
      }
    }
    final runtime = await _readRuntimeNetworkInfo();
    map["network-transport-type"] = runtime.$1;
    map["network-interface-mtu"] = runtime.$2;

    final userRules = await _loadUserRouteRulesFromProto();
    if (userRules.isNotEmpty) {
      map["rules"] = userRules;
    }

    loggy.info(
      "core options prepared: full-config=$fullConfig transport=${runtime.$1} iface-mtu=${runtime.$2} user-rules=${(map["rules"] as List?)?.length ?? 0}",
    );
    return map;
  }

  Map<String, dynamic> _safeCorePayload(Map<String, dynamic> payload) {
    final safe = <String, dynamic>{
      "network-profile": payload["network-profile"],
      "network-mtu-mode": payload["network-mtu-mode"],
      "network-transport-type": payload["network-transport-type"],
      "network-interface-mtu": payload["network-interface-mtu"],
      "enable-full-config": payload["enable-full-config"],
      "execute-config-as-is": payload["execute-config-as-is"],
      "fragment-mode": payload["fragment-mode"],
      "profile-dns-strategy": payload["profile-dns-strategy"],
      "selector-interrupt-exist-connections": payload["selector-interrupt-exist-connections"],
      "selector-tolerance": payload["selector-tolerance"],
      "selector-use-sticky": payload["selector-use-sticky"],
      "critical-domains-fallback-enabled": payload["critical-domains-fallback-enabled"],
      "mtu": payload["mtu"],
      "tun-implementation": payload["tun-implementation"],
      "ipv6-mode": payload["ipv6-mode"],
      "remote-dns-domain-strategy": payload["remote-dns-domain-strategy"],
      "direct-dns-domain-strategy": payload["direct-dns-domain-strategy"],
      "block-quic": payload["block-quic"],
      "strict-route": payload["strict-route"],
      "udp-probe-enabled": payload["udp-probe-enabled"],
      "udp-probe-endpoint": payload["udp-probe-endpoint"],
      "udp-probe-count": payload["udp-probe-count"],
      "udp-probe-size": payload["udp-probe-size"],
      "udp-probe-timeout-ms": payload["udp-probe-timeout-ms"],
      "udp-probe-top-n": payload["udp-probe-top-n"],
      "rules-count": (payload["rules"] as List?)?.length ?? 0,
    };
    return safe;
  }

  Future<List<Map<String, dynamic>>> _loadUserRouteRulesFromProto() async {
    try {
      final directories = ref.read(appDirectoriesProvider).requireValue;
      final file = File('${directories.baseDir.path}/route_rule.proto');
      if (!await file.exists()) return const [];
      final bytes = await file.readAsBytes();
      final rr = route_rule.RouteRule.fromBuffer(bytes);
      if (rr.rules.isEmpty) return const [];

      final sorted = rr.rules.toList()..sort((a, b) => a.listOrder.compareTo(b.listOrder));
      return sorted.map(_routeRuleToCoreJson).toList();
    } catch (e, st) {
      loggy.warning("failed reading route_rule.proto; keep existing options.rules", e, st);
      return const [];
    }
  }

  Map<String, dynamic> _routeRuleToCoreJson(route_rule.Rule rule) {
    final map = <String, dynamic>{
      "list_order": rule.listOrder,
      "enabled": rule.enabled,
      "name": rule.name,
      "outbound": rule.outbound.value,
    };
    if (rule.ruleSets.isNotEmpty) map["rule_sets"] = rule.ruleSets;
    if (rule.packageNames.isNotEmpty) map["package_names"] = rule.packageNames;
    if (rule.processNames.isNotEmpty) map["process_names"] = rule.processNames;
    if (rule.processPaths.isNotEmpty) map["process_paths"] = rule.processPaths;
    if (rule.network.value != route_rule.Network.all.value) map["network"] = rule.network.value;
    if (rule.portRanges.isNotEmpty) map["port_ranges"] = rule.portRanges;
    if (rule.sourcePortRanges.isNotEmpty) map["source_port_ranges"] = rule.sourcePortRanges;
    if (rule.protocols.isNotEmpty) map["protocols"] = rule.protocols.map((e) => e.value).toList();
    if (rule.ipCidrs.isNotEmpty) map["ip_cidrs"] = rule.ipCidrs;
    if (rule.sourceIpCidrs.isNotEmpty) map["source_ip_cidrs"] = rule.sourceIpCidrs;
    if (rule.domains.isNotEmpty) map["domains"] = rule.domains;
    if (rule.domainSuffixes.isNotEmpty) map["domain_suffixes"] = rule.domainSuffixes;
    if (rule.domainKeywords.isNotEmpty) map["domain_keywords"] = rule.domainKeywords;
    if (rule.domainRegexes.isNotEmpty) map["domain_regexes"] = rule.domainRegexes;
    return map;
  }

  Future<(String, int)> _readRuntimeNetworkInfo() async {
    if (!PlatformUtils.isAndroid) return ("unknown", 0);
    try {
      final info = await _platformChannel.invokeMapMethod<String, dynamic>("get_network_runtime_info");
      final transportRaw = (info?["network-transport-type"] ?? "unknown").toString().toLowerCase().trim();
      final transport = switch (transportRaw) {
        "wifi" => "wifi",
        "cellular" => "cellular",
        "ethernet" => "ethernet",
        _ => "unknown",
      };
      final mtuDynamic = info?["network-interface-mtu"];
      final mtu = switch (mtuDynamic) {
        final int v => v,
        final num v => v.toInt(),
        final String v => int.tryParse(v) ?? 0,
        _ => 0,
      };
      return (transport, mtu < 0 ? 0 : mtu);
    } catch (_) {
      return ("unknown", 0);
    }
  }

  TaskEither<ConnectionFailure, Unit> start(String path, String name, bool disableMemoryLimit) {
    return TaskEither(
      () => _enqueueLifecycle("start", () async {
        if (_useMockCore) {
          _transitionLifecycle(_CoreLifecycleState.starting, reason: "mock start");
          statusController.add(currentState = const CoreStatus.starting());
          await Future<void>.delayed(const Duration(milliseconds: 180));
          _transitionLifecycle(_CoreLifecycleState.started, reason: "mock start complete");
          statusController.add(currentState = const CoreStatus.started());
          return right(unit);
        }

        if (_isMissingWindowsTunPrivilege()) {
          loggy.warning("VPN mode on Windows requires administrator privileges");
          return left(const ConnectionFailure.missingPrivilege());
        }

        if (_lifecycleState == _CoreLifecycleState.started && currentState == const CoreStatus.started()) {
          loggy.debug("start ignored: already started");
          return right(unit);
        }

        _clearRuntimeOutboundSnapshot("start requested");
        _transitionLifecycle(_CoreLifecycleState.starting, reason: "start requested");
        statusController.add(currentState = const CoreStatus.starting());
        loggy.debug("starting");

        final CoreStatus background;
        try {
          background = await core.setupBackground(path, name);
        } catch (e, st) {
          await _deleteCoreCurrentConfigSnapshot();
          loggy.error("failed to setup background core", e, st);
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "background setup error");
          statusController.add(currentState = const CoreStatus.stopped());
          return left(const ConnectionFailure.unexpected("failed to setup background core"));
        }
        if (background != const CoreStatus.started()) {
          await _deleteCoreCurrentConfigSnapshot();
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "background setup failed");
          statusController.add(currentState = const CoreStatus.stopped());
          return left(background.getCoreAlert() ?? const ConnectionFailure.unexpected("failed to start core"));
        }

        if (!core.isSingleChannel()) {
          await startListeningLogs("bg", core.bgClient);
          await startListeningStatus("bg", core.bgClient);
        }

        final optionsResult = await _applyLatestCoreOptionsToBackground("start");
        if (optionsResult.isLeft()) {
          final error = optionsResult.getLeft().toNullable() ?? "failed to apply core options";
          await _deleteCoreCurrentConfigSnapshot();
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "background options failed");
          statusController.add(currentState = const CoreStatus.stopped());
          return left(ConnectionFailure.unexpected("failed to apply core options: $error"));
        }

        try {
          final res = await core.bgClient.start(
            StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit),
          );
          ref.read(coreRestartSignalProvider.notifier).restart();
          if (res.messageType != MessageType.ALREADY_STARTED && res.messageType != MessageType.EMPTY) {
            final alert = res.message.contains("denied") ? CoreAlert.requestVPNPermission : CoreAlert.startFailed;
            currentState = CoreStatus.stopped(
              alert: alert,
              message: "failed to start core ${res.messageType} ${res.message}",
            );
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "start rejected by core");
            statusController.add(currentState);
            return left(
              currentState.getCoreAlert() ??
                  ConnectionFailure.unexpected("failed to start core ${res.messageType} ${res.message}"),
            );
          }
        } on GrpcError catch (e) {
          loggy.error("failed to start bg core: $e");
          ref.read(coreRestartSignalProvider.notifier).restart();
          if (_isTransientGrpcTransportClose(e) && await _isBackgroundCoreReachable()) {
            loggy.warning("start bg core transport closed after start, but background core is active: $e");
            _transitionLifecycle(_CoreLifecycleState.started, reason: "start transport closed with active bg");
            statusController.add(currentState = const CoreStatus.started());
            return right(unit);
          }
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "grpc error on start");
          if (_isMissingWindowsTunPrivilege()) {
            return left(const ConnectionFailure.missingPrivilege());
          }
          if (e.code == StatusCode.unavailable) {
            return left(const ConnectionFailure.unexpected("background core is not started yet!"));
          }
          return left(const ConnectionFailure.unexpected("failed to start background core"));
        } finally {
          await _deleteCoreCurrentConfigSnapshot();
        }

        _transitionLifecycle(_CoreLifecycleState.started, reason: "start complete");
        statusController.add(currentState = const CoreStatus.started());
        return right(unit);
      }),
    );
  }

  TaskEither<String, Unit> prepareVpnConfiguration(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      if (!PlatformUtils.isIOS || _useMockCore) return right(unit);
      try {
        final prepared = await core.prepareVpn(path, name, disableMemoryLimit);
        return prepared ? right(unit) : left("failed to prepare VPN configuration");
      } catch (e) {
        return left(e.toString());
      }
    });
  }

  bool _isMissingWindowsTunPrivilege() {
    if (!PlatformUtils.isWindows || ref.read(ConfigOptions.serviceMode) != ServiceMode.tun) {
      return false;
    }
    try {
      return isWindowsProcessElevated() == false;
    } catch (e, st) {
      loggy.warning("failed to check Windows process privilege", e, st);
      return false;
    }
  }

  TaskEither<String, Unit> stop({bool force = false}) {
    return TaskEither(
      () => _enqueueLifecycle("stop", () async {
        if (_useMockCore) {
          _transitionLifecycle(_CoreLifecycleState.stopping, reason: "mock stop");
          statusController.add(currentState = const CoreStatus.stopping());
          await Future<void>.delayed(const Duration(milliseconds: 120));
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "mock stop complete");
          statusController.add(currentState = const CoreStatus.stopped());
          return right(unit);
        }

        if (!force && _lifecycleState == _CoreLifecycleState.stopped && currentState == const CoreStatus.stopped()) {
          loggy.debug("stop ignored: already stopped");
          return right(unit);
        }

        _transitionLifecycle(_CoreLifecycleState.stopping, reason: "stop requested");
        statusController.add(currentState = const CoreStatus.stopping());
        loggy.debug("stopping");

        var errMsg = "";
        try {
          await core.bgClient.stop(Empty(), options: CallOptions(timeout: const Duration(seconds: 3)));
        } on GrpcError catch (e) {
          if (!_isTransientGrpcTransportClose(e)) {
            errMsg = e.message ?? "failed to stop core: $e";
            loggy.error("failed to stop bg core: $e");
          }
        } catch (e) {
          loggy.error("failed to stop bg core: $e");
        }
        var nativeStopped = true;
        try {
          nativeStopped = await core.stop().timeout(const Duration(seconds: 14), onTimeout: () => false);
        } finally {
          await _deleteCoreCurrentConfigSnapshot();
        }
        if (!nativeStopped) {
          loggy.warning("native core stop timed out; forcing local stopped state");
        }

        _transitionLifecycle(_CoreLifecycleState.stopped, reason: "stop complete");
        _clearRuntimeOutboundSnapshot("stop complete");
        statusController.add(currentState = const CoreStatus.stopped());
        if (errMsg.isNotEmpty) return left(errMsg);
        return right(unit);
      }),
    );
  }

  TaskEither<String, Unit> restart(String path, String name, bool disableMemoryLimit) {
    if (_lifecycleState == _CoreLifecycleState.starting || _lifecycleState == _CoreLifecycleState.stopping) {
      loggy.info("restart requested during ${_lifecycleState.name}; queued");
    }
    return TaskEither(
      () => _enqueueLifecycle("restart", () async {
        if (_useMockCore) {
          _transitionLifecycle(_CoreLifecycleState.stopping, reason: "mock restart");
          statusController.add(currentState = const CoreStatus.stopping());
          await Future<void>.delayed(const Duration(milliseconds: 80));
          _transitionLifecycle(_CoreLifecycleState.starting, reason: "mock restart");
          statusController.add(currentState = const CoreStatus.starting());
          await Future<void>.delayed(const Duration(milliseconds: 140));
          _transitionLifecycle(_CoreLifecycleState.started, reason: "mock restart complete");
          statusController.add(currentState = const CoreStatus.started());
          return right(unit);
        }

        loggy.debug("restarting");
        _transitionLifecycle(_CoreLifecycleState.stopping, reason: "restart requested");
        statusController.add(currentState = const CoreStatus.stopping());

        try {
          final optionsResult = await _applyLatestCoreOptionsToBackground("restart");
          if (optionsResult.isLeft()) {
            final error = optionsResult.getLeft().toNullable() ?? "failed to apply core options";
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "restart options failed");
            statusController.add(currentState = const CoreStatus.stopped());
            return left("failed to apply core options: $error");
          }
          final res = await core.bgClient.restart(
            StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit, delayStart: true),
          );
          if (res.messageType != MessageType.EMPTY) {
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "restart failed");
            statusController.add(currentState = const CoreStatus.stopped());
            return left("${res.messageType} ${res.message}");
          }
        } on GrpcError catch (e) {
          loggy.error("failed to restart bg core: $e");
          if (!_isTransientGrpcTransportClose(e)) {
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "grpc restart failure");
            statusController.add(currentState = const CoreStatus.stopped());
            return left("${e.message}");
          }
        } finally {
          await _deleteCoreCurrentConfigSnapshot();
        }

        _transitionLifecycle(_CoreLifecycleState.starting, reason: "restart in progress");
        statusController.add(currentState = const CoreStatus.starting());
        _transitionLifecycle(_CoreLifecycleState.started, reason: "restart complete");
        statusController.add(currentState = const CoreStatus.started());
        ref.read(coreRestartSignalProvider.notifier).restart();
        return right(unit);
      }),
    );
  }

  Future<void> _deleteCoreCurrentConfigSnapshot() async {
    try {
      final directories = ref.read(appDirectoriesProvider).requireValue;
      final file = File(p.join(directories.workingDir.path, "data", "current-config.json"));
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e, st) {
      loggy.warning("failed to delete core current config snapshot", e, st);
    }
  }

  TaskEither<String, Unit> resetTunnel() {
    return TaskEither(() async {
      // only available on iOS (and macOS later)
      if (!PlatformUtils.isIOS) {
        throw UnimplementedError("reset tunnel function unavailable on platform");
      }

      // loggy.debug("resetting tunnel");
      final res = await core.resetTunnel();
      if (res) {
        return right(unit);
      }
      return left("failed to reset tunnel");
    });
  }

  // Stream<List<OutboundGroup>> watchGroups() async* {
  //   loggy.debug("watching groups");
  //   yield* core.bgClient.outboundsInfo(Empty()).map((event) => event.items);
  //   // res?.cancel();
  // }

  Stream<OutboundGroup?> watchGroup() async* {
    loggy.debug("watching group");
    // interrupt managed by core
    if (_useMockCore) {
      _ensureMockGroups();
      yield* _mockGroupsController.stream
          .asyncMap((groups) async {
            await Future<void>.delayed(Duration.zero);
            return groups;
          })
          .map((groups) => groups.isEmpty ? null : groups.first);
      return;
    }

    if (!await _ensureCoreInitializedForStream("watch group")) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }
    final cached = _firstOutboundGroupSnapshot();
    if (cached != null) {
      loggy.debug("yielding cached group snapshot before live stream");
      yield cached;
    }

    while (_lifecycleState != _CoreLifecycleState.stopped) {
      try {
        final snapshot = await core.bgClient
            .outboundsInfo(Empty())
            .map((event) {
              _rememberOutboundGroups(event.items, "outboundsInfo initial");
              return _firstOutboundGroupSnapshot();
            })
            .first
            .timeout(const Duration(seconds: 2));
        if (snapshot != null) yield snapshot;
      } catch (e, st) {
        loggy.debug("failed to read initial group snapshot", e, st);
      }

      try {
        await for (final event in core.bgClient.outboundsInfo(Empty())) {
          _rememberOutboundGroups(event.items, "outboundsInfo stream");
          yield _firstOutboundGroupSnapshot();
        }
        if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) {
          return;
        }
        loggy.debug("group stream ended; retrying with cached snapshot");
        await Future<void>.delayed(_listenerReconnectDelay("watchGroup"));
      } catch (e, st) {
        if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) {
          loggy.debug("group stream closed during ${_lifecycleState.name}", e, st);
          return;
        }
        loggy.warning("group stream interrupted; retrying with cached snapshot", e, st);
        final fallback = _firstOutboundGroupSnapshot();
        if (fallback != null) yield fallback;
        await Future<void>.delayed(_listenerReconnectDelay("watchGroup"));
      }
    }
    // //emitting first event immediately
    // yield* core.bgClient.outboundsInfo(Empty()).take(1).map((event) => event.items.isEmpty ? null : event.items.first);
    // //emitting other event after every 4 seconds(latest event)
    // yield* core.bgClient.outboundsInfo(Empty()).throttleTime(const Duration(seconds: 4), leading: false, trailing: true).map((event) => event.items.isEmpty ? null : event.items.first);
  }

  Stream<List<OutboundGroup>> watchActiveGroups() async* {
    loggy.info("watching active groups");
    if (_useMockCore) {
      _ensureMockGroups();
      yield* _mockGroupsController.stream.asyncMap((groups) async {
        await Future<void>.delayed(Duration.zero);
        return groups;
      });
      return;
    }

    if (!await _ensureCoreInitializedForStream("watch active groups")) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }

    final cached = _outboundGroupsSnapshot();
    if (cached.isNotEmpty) {
      loggy.debug("yielding cached active groups before live stream");
      yield cached;
    }

    while (_lifecycleState != _CoreLifecycleState.stopped) {
      try {
        await for (final event in core.bgClient.mainOutboundsInfo(Empty())) {
          _rememberOutboundGroups(event.items, "mainOutboundsInfo stream");
          yield _outboundGroupsSnapshot();
        }
        if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) {
          return;
        }
        loggy.debug("active group stream ended; retrying with cached snapshot");
        await Future<void>.delayed(_listenerReconnectDelay("watchActiveGroups"));
      } catch (e, st) {
        if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) {
          loggy.debug("active group stream closed during ${_lifecycleState.name}", e, st);
          return;
        }
        loggy.warning("active group stream interrupted; retrying with cached snapshot", e, st);
        final fallback = _outboundGroupsSnapshot();
        if (fallback.isNotEmpty) yield fallback;
        await Future<void>.delayed(_listenerReconnectDelay("watchActiveGroups"));
      }
    }
  }

  //
  // Stream<SingboxStatus> watchStatus() => _status;

  Stream<SystemInfo> watchStats() async* {
    if (_useMockCore) {
      return;
    }
    if (!await _ensureCoreInitializedForStream("watch stats")) {
      return;
    }
    loggy.debug("watching stats");
    try {
      try {
        yield await core.bgClient.getSystemInfo(Empty());
      } catch (e, st) {
        loggy.debug("failed to read initial stats snapshot", e, st);
      }
      yield* core.bgClient.getSystemInfoStream(Empty());
    } catch (e) {
      loggy.error("error watching stats: $e");
      rethrow;
    }
  }

  TaskEither<String, Unit> selectOutbound(String groupTag, String outboundTag) {
    return TaskEither(() async {
      if (_useMockCore) {
        _ensureMockGroups();
        final groups = latest;
        if (groups.isEmpty) return right(unit);

        OutboundGroup group = groups.first;
        for (final candidate in groups) {
          if (candidate.tag == groupTag) {
            group = candidate;
            break;
          }
        }
        if (group.items.isEmpty) return right(unit);

        var selectedIndex = 0;
        for (var i = 0; i < group.items.length; i++) {
          final item = group.items[i];
          final isSelected = item.tag == outboundTag;
          item.isSelected = isSelected;
          if (isSelected) {
            selectedIndex = i;
            group.selected = item.tag;
          }
        }

        if (selectedIndex > 0 && selectedIndex < group.items.length) {
          final selected = group.items.removeAt(selectedIndex);
          group.items.insert(0, selected);
        }

        _emitMockGroups(deferred: true);
        return right(unit);
      }
      loggy.debug("selecting outbound");
      try {
        final res = await core.bgClient.selectOutbound(
          SelectOutboundRequest(groupTag: groupTag, outboundTag: outboundTag),
          options: CallOptions(timeout: const Duration(seconds: 1)),
        );
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error selecting outbound: $e");
        rethrow;
      }
    });
  }

  TaskEither<String, Unit> urlTest(String tag) {
    return TaskEither(() async {
      if (_useMockCore) {
        _ensureMockGroups();
        final random = Random();
        for (final group in latest) {
          for (final item in group.items) {
            final roll = random.nextInt(100);
            if (roll < 8) {
              item.urlTestDelay = 65001;
              item.success = false;
              item.errorType = 'timeout';
              item.healthScore = 20;
            } else {
              item.urlTestDelay = 80 + random.nextInt(260);
              item.success = true;
              item.errorType = 'none';
              item.healthScore = item.urlTestDelay < 150 ? 90 : 75;
              item.udpProbeAvailable = roll % 3 == 0;
              item.udpLoss = item.udpProbeAvailable ? random.nextInt(6).toDouble() : 0;
              item.udpJitterMs = item.udpProbeAvailable ? 8 + random.nextInt(45) : 0;
              item.udpPenalty = item.udpProbeAvailable && item.udpLoss > 3 ? 4 : 0;
            }
          }
        }
        _emitMockGroups(deferred: true);
        return right(unit);
      }
      loggy.debug("url test");
      try {
        final res = await core.bgClient.urlTest(UrlTestRequest(tag: tag));
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error in url test: $e");
        rethrow;
      }
    });
  }

  List<LogMessage> logBuffer = [];

  // SingboxConfigOption? latestOptions;

  Stream<List<LogMessage>> watchLogs(String path) async* {
    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty log stream");
      return;
    }
    await startListeningLogs("bg", core.bgClient);
    await startListeningLogs("fg", core.fgClient);
    try {
      yield* logController.stream;
    } catch (e) {
      loggy.error("error watching logs: $e");
      rethrow;
    }
    // Stream<List<String>> logStream(CoreClient coreClient) {
    //   return coreClient.logListener(Empty()).asBroadcastStream().map((event) => [event.message]).onErrorResume((error, stackTrace) {
    //     loggy.debug('Error in $coreClient: $error, retrying...');
    //     final delay = (currentState == const SingboxStatus.stopped()) ? 5 : 1;
    //     return const Stream<List<String>>.empty().delay(Duration(seconds: delay)).concatWith([logStream(coreClient)]);
    //   });
    // }

    // // Create streams for both fg and bg clients with retry logic
    // final fgLogStream = logStream(core.fgClient);

    // if (core.bgClient == core.fgClient) {
    //   yield* fgLogStream;
    //   return;
    // }
    // final bgLogStream = logStream(core.bgClient);
    // yield* MergeStream([bgLogStream, fgLogStream]);
  }

  TaskEither<String, Unit> clearLogs() {
    return TaskEither(() async {
      loggy.debug("clearing logs");
      logBuffer.clear();
      // final res = await core.bgClient(Empty());
      // if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");
      return right(unit);
    });
  }

  TaskEither<String, WarpResponse> generateWarpConfig({
    required String licenseKey,
    required String previousAccountId,
    required String previousAccessToken,
  }) {
    return TaskEither(() async {
      loggy.debug("generating warp config");
      final warpConfig = await core.fgClient.generateWarpConfig(
        GenerateWarpConfigRequest(
          licenseKey: licenseKey,
          accountId: previousAccountId,
          accessToken: previousAccessToken,
        ),
      );
      // if (warpConfig.code != ResponseCode.OK) return left("${warpConfig.code} ${warpConfig.message}");
      final WarpResponse warp = (
        log: warpConfig.log,
        accountId: warpConfig.account.accountId,
        accessToken: warpConfig.account.accessToken,
        wireguardConfig: jsonEncode(warpConfig.config.toProto3Json()),
      );
      return right(warp);
    });
  }

  Stream<CoreStatus> watchStatus() async* {
    if (_useMockCore) {
      if (!statusController.hasValue) {
        statusController.add(currentState = const CoreStatus.stopped());
      }
      yield* statusController.stream;
      return;
    }
    try {
      if (core.isSingleChannel() || await core.isActiveBg()) {
        await startListeningStatus("bg", core.bgClient);
      }
    } catch (e) {
      loggy.debug("background core is not ready for status listener: $e");
    }
    if (!statusController.hasValue) {
      statusController.add(currentState);
    }
    yield* statusController.stream;
    // .endWith(const CoreStatus.stopped());
  }

  Future<void> startListeningStatus(String key, CoreClient cc) async {
    final listenKey = "${key}StatusListener";
    await listenSingle<CoreStatus>(
      listenKey,
      () => cc
          .coreInfoListener(Empty(), options: grpcOptions)
          .doOnCancel(() {
            loggy.debug("status listener canceled [$key]");
          })
          .doOnData((event) {
            loggy.debug("status", event);
          })
          .doOnDone(() {
            loggy.debug("status listener done [$key]");
          })
          .asyncMap((event) => _applyCoreStatusFromListener(key, CoreStatus.fromCoreInfo(event))),
      onDone: () {
        loggy.warning("status listener closed [$key], scheduling reconnect");
        _recoverStatusAfterListenerClose(key, null);
        _scheduleListenerReconnect(listenKey, () => startListeningStatus(key, cc));
      },
      onError: (error) {
        loggy.error("Stream error in $listenKey: $error");
        _recoverStatusAfterListenerClose(key, error);
        _scheduleListenerReconnect(listenKey, () => startListeningStatus(key, cc));
      },
    );
  }

  Future<void> startListeningLogs(String key, CoreClient cc) async {
    final coreLogLevel = getCoreLogLevel(config_log_level.LogLevel.warn);
    final listenKey = "${key}LogListener";
    await listenSingle<LogMessage>(
      listenKey,
      () {
        return cc.logListener(LogRequest(level: coreLogLevel), options: grpcOptions).map((event) {
          final safeEvent = event.deepCopy()..message = _redactCoreLogMessage(event.message);
          // Handle incoming event
          logBuffer.add(safeEvent);
          if (logBuffer.length > 300) {
            logBuffer.removeAt(0);
          }
          logController.add(logBuffer);
          // loggy.log(getLogLevel(event.level), event.message);
          safeEvent.message.split('\n').forEach((line) {
            loggy.log(getLogLevel(safeEvent.level), line);
          });
          return safeEvent;
        });
      },
      onDone: () {
        loggy.warning("log listener closed [$key], scheduling reconnect");
        _scheduleListenerReconnect(listenKey, () => startListeningLogs(key, cc));
      },
      onError: (error) {
        loggy.error("Stream error in $listenKey: $error");
        _scheduleListenerReconnect(listenKey, () => startListeningLogs(key, cc));
      },
    );
  }

  String _redactCoreLogMessage(String message) {
    var safe = message;
    safe = safe.replaceAll(
      RegExp(r'\b(vless|vmess|trojan|ss|hysteria2?)://\S+', caseSensitive: false),
      '<redacted-link>',
    );
    safe = safe.replaceAll(
      RegExp(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', caseSensitive: false),
      '<redacted-uuid>',
    );
    safe = safe.replaceAllMapped(
      RegExp(r'\b(public_key|short_id|uuid|password|token)=([^&\s]+)', caseSensitive: false),
      (match) => '${match.group(1)}=<redacted>',
    );
    safe = safe.replaceAll(
      RegExp(r'\b(outbound)/(vless|vmess|trojan|ss|hysteria2?|shadowsocks)\[[^\]]*\]', caseSensitive: false),
      'outbound/<redacted>',
    );
    safe = safe.replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}\b'), '<redacted-endpoint>');
    safe = safe.replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '<redacted-ip>');
    return safe;
  }

  Future<void> stopListenSingle(String key) async {
    // Collect keys to remove first
    final keysToRemove = subscriptions.entries
        .where((entry) => entry.key.startsWith(key))
        .map((entry) => entry.key)
        .toList();

    // Cancel and remove
    for (final k in keysToRemove) {
      final sub = subscriptions[k];
      await sub?.cancel(); // cancel the subscription

      subscriptions.remove(k);
      _listenerReconnectAttempt.remove(k);
    }
  }

  Future<StreamSubscription<T>?> listenSingle<T>(
    String key,
    Stream<T> Function() stream, {
    Function(dynamic error)? onError,
    VoidCallback? onDone,
  }) async {
    if (subscriptions.containsKey(key)) {
      // return subscriptions[key] as StreamSubscription<T>?;
      await stopListenSingle(key);
    }
    subscriptions[key] = null;
    var streamFailed = false;
    subscriptions[key] = stream().listen(
      (_) {
        _listenerReconnectAttempt[key] = 0;
      },
      cancelOnError: true,
      onError: (error) {
        streamFailed = true;
        loggy.log(loggyl.LogLevel.error, 'Stream error: $error');
        onError?.call(error);
        subscriptions[key]?.cancel();
        subscriptions.remove(key);
      },
      onDone: () {
        subscriptions.remove(key);
        if (!streamFailed) {
          onDone?.call();
        }
      },
    );
    return subscriptions[key] as StreamSubscription<T>?;
  }

  loggyl.LogLevel getLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.DEBUG => loggyl.LogLevel.debug,
      LogLevel.INFO => loggyl.LogLevel.info,
      LogLevel.WARNING => loggyl.LogLevel.warning,
      LogLevel.ERROR => loggyl.LogLevel.error,
      LogLevel.FATAL => loggyl.LogLevel.error,
      _ => loggyl.LogLevel.info, // Default case
    };
  }

  LogLevel getCoreLogLevel(config_log_level.LogLevel level) {
    return switch (level) {
      config_log_level.LogLevel.trace => LogLevel.TRACE,
      config_log_level.LogLevel.debug => LogLevel.DEBUG,
      config_log_level.LogLevel.info => LogLevel.INFO,
      config_log_level.LogLevel.warn => LogLevel.WARNING,
      config_log_level.LogLevel.error => LogLevel.ERROR,
      config_log_level.LogLevel.fatal => LogLevel.FATAL,
      config_log_level.LogLevel.panic => LogLevel.FATAL,
    };
  }

  Future<void> closeFront() async {
    if (!core.isInitialized()) {
      return;
    }
    var bgStillActive = false;
    if (!core.isSingleChannel()) {
      try {
        bgStillActive = await core.isActiveBg();
      } catch (_) {
        // Best-effort lifecycle sync; fall through as inactive when bg check fails.
      }
    }
    if (!core.isSingleChannel()) {
      await stopListenSingle("fg");
      await stopListenSingle("bg");
      try {
        await core.fgClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL_INSECURE));
      } catch (_) {
        // Best-effort close; the alternate mode below may still succeed.
      }
      try {
        await core.fgClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL));
      } catch (_) {
        // Best-effort close during shutdown.
      }
    }
    if (bgStillActive) {
      _transitionLifecycle(_CoreLifecycleState.started, reason: "close front while bg active");
      if (currentState != const CoreStatus.started()) {
        currentState = const CoreStatus.started();
        statusController.add(currentState);
      }
    } else {
      _transitionLifecycle(_CoreLifecycleState.stopped, reason: "close front");
      if (currentState != const CoreStatus.stopped()) {
        currentState = const CoreStatus.stopped();
        statusController.add(currentState);
      }
    }
  }
}
