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
import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
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
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_wrapper_stub.dart'
    if (dart.library.io) 'package:zeon/zeoncore/core_interface/core_interface_wrapper.dart';
import 'package:zeon/zeoncore/generated/v2/config/route_rule.pb.dart' as route_rule;
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/global_data_plane_config_redactor.dart';
import 'package:zeon/zeoncore/init_signal.dart';
import 'package:zeon/zeoncore/session_generation.dart';
import 'package:zeon/zeoncore/startup_failure_classification.dart';
import 'package:zeon/zeoncore/vpn_diagnostics.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

enum _CoreLifecycleState { stopped, starting, started, stopping }

enum TransportCloseIntent { none, stop, restartReplacement, foregroundClose }

enum TransportCloseStage { teardown, start, listener }

enum TransportCloseDisposition { expectedTeardown, recovered, realFailure }

@visibleForTesting
TransportCloseDisposition classifyTransportClose({
  required TransportCloseIntent intent,
  required TransportCloseStage stage,
  required int operationGeneration,
  required bool operationCurrent,
  required bool backgroundCoreActive,
  required bool controlRecoverySucceeded,
  required VpnSessionSnapshot? nativeSnapshot,
  required bool explicitFailure,
}) {
  final snapshot = nativeSnapshot;
  if (!operationCurrent) return TransportCloseDisposition.expectedTeardown;

  final snapshotMatchesOperation = snapshot != null && snapshot.generation == operationGeneration;
  final nativeFailed = snapshotMatchesOperation && snapshot.phase == VpnSessionPhase.failed;
  if (explicitFailure || nativeFailed) return TransportCloseDisposition.realFailure;

  final nativeStopSourceIsIntentional =
      snapshotMatchesOperation &&
      switch (snapshot.stopSource) {
        VpnStopSource.flutter ||
        VpnStopSource.notification ||
        VpnStopSource.tile ||
        VpnStopSource.shortcut ||
        VpnStopSource.revoke ||
        VpnStopSource.replacement => true,
        _ => false,
      };
  final nativeStop =
      snapshotMatchesOperation &&
      nativeStopSourceIsIntentional &&
      snapshot.requestedAction == 'stop' &&
      switch (snapshot.phase) {
        VpnSessionPhase.stopRequested || VpnSessionPhase.stopping || VpnSessionPhase.disconnected => true,
        _ => false,
      };
  final explicitTeardown = stage == TransportCloseStage.teardown && intent != TransportCloseIntent.none;
  if (explicitTeardown || nativeStop) {
    return TransportCloseDisposition.expectedTeardown;
  }

  final nativeConnected = snapshotMatchesOperation && snapshot.provesConnected;
  if (controlRecoverySucceeded && (backgroundCoreActive || nativeConnected)) {
    return TransportCloseDisposition.recovered;
  }
  return TransportCloseDisposition.realFailure;
}

enum CloseFrontBackgroundState { active, inactive, unknown }

enum CloseFrontPublicationDecision {
  publishStarted,
  preserveStarted,
  publishStopped,
  preserveStopped,
  preserveUnknown,
  preserveLifecycleIntent,
  nativeConnectedOverride,
  skipStaleOperation,
}

enum LocalControlStatusDecision { publishStarted, publishStopped, preserve }

LocalControlStatusDecision classifyLocalControlStatus({
  required CloseFrontBackgroundState backgroundState,
  required bool nativeProvesConnected,
  required bool nativeProvesStopped,
}) {
  if (nativeProvesConnected) return LocalControlStatusDecision.publishStarted;
  if (nativeProvesStopped) return LocalControlStatusDecision.publishStopped;
  return switch (backgroundState) {
    CloseFrontBackgroundState.active => LocalControlStatusDecision.publishStarted,
    CloseFrontBackgroundState.inactive => LocalControlStatusDecision.publishStopped,
    CloseFrontBackgroundState.unknown => LocalControlStatusDecision.preserve,
  };
}

@visibleForTesting
CloseFrontBackgroundState closeFrontBackgroundState({
  required bool singleChannel,
  required bool backgroundActive,
  required PortProbeObservation? observation,
}) {
  if (singleChannel) return CloseFrontBackgroundState.unknown;
  return switch (observation?.outcome) {
    PortProbeOutcome.connected => CloseFrontBackgroundState.active,
    PortProbeOutcome.closed => CloseFrontBackgroundState.inactive,
    PortProbeOutcome.timeout ||
    PortProbeOutcome.socketError ||
    PortProbeOutcome.otherError => CloseFrontBackgroundState.unknown,
    null => backgroundActive ? CloseFrontBackgroundState.active : CloseFrontBackgroundState.unknown,
  };
}

@visibleForTesting
CloseFrontPublicationDecision classifyCloseFrontPublication({
  required bool operationCurrent,
  required CloseFrontBackgroundState backgroundState,
  required bool nativeProvesConnected,
  required bool lifecycleIntentReserved,
  required CoreStatus currentStatus,
}) {
  if (!operationCurrent) return CloseFrontPublicationDecision.skipStaleOperation;
  if (lifecycleIntentReserved) return CloseFrontPublicationDecision.preserveLifecycleIntent;
  if (backgroundState == CloseFrontBackgroundState.active) {
    return currentStatus is CoreStarted
        ? CloseFrontPublicationDecision.preserveStarted
        : CloseFrontPublicationDecision.publishStarted;
  }
  if (nativeProvesConnected) return CloseFrontPublicationDecision.nativeConnectedOverride;
  if (backgroundState == CloseFrontBackgroundState.unknown) {
    return CloseFrontPublicationDecision.preserveUnknown;
  }
  return currentStatus is CoreStopped
      ? CloseFrontPublicationDecision.preserveStopped
      : CloseFrontPublicationDecision.publishStopped;
}

class ZeonCoreService with InfraLogger {
  ZeonCoreService(this.ref, {CoreInterface? coreInterface}) : core = coreInterface ?? getCoreInterface() {
    _platformSnapshotSubscription = core.watchSessionSnapshots().listen(
      _queuePlatformSessionSnapshot,
      onError: (Object error, StackTrace stackTrace) {
        loggy.warning("Android VPN snapshot bridge failed", error, stackTrace);
      },
    );
    ref.onDispose(() {
      unawaited(_platformSnapshotSubscription.cancel());
      unawaited(_authoritativeSnapshotController.close());
    });
  }
  final Ref ref;
  static const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");
  static const _debugNetworkProfile = String.fromEnvironment("debug_network_profile");
  static const _debugNetworkMtuMode = String.fromEnvironment("debug_network_mtu_mode");
  static const _debugFragmentMode = String.fromEnvironment("debug_fragment_mode");
  static const _debugProfileDnsStrategy = String.fromEnvironment("debug_profile_dns_strategy");
  static const _debugTunImplementation = String.fromEnvironment("debug_tun_implementation");
  static const _routeEvidenceLogcatEnabled = bool.fromEnvironment("route_evidence_logcat_enabled");
  static const _globalDataPlaneValidationEnabled = bool.fromEnvironment("global_data_plane_validation_enabled");
  // Release builds may receive the authenticated UDP probe settings from CI.
  // The secret is never copied into diagnostic logs or the safe payload dump.
  static const _udpProbeEnabled = bool.fromEnvironment("udp_probe_enabled");
  static const _udpProbeEndpoint = String.fromEnvironment("udp_probe_endpoint");
  static const _udpProbeSecret = String.fromEnvironment("udp_probe_secret");
  static const _debugUdpProbeEnabled = kDebugMode && bool.fromEnvironment("debug_udp_probe_enabled");
  static const _debugUdpProbeEndpoint = String.fromEnvironment("debug_udp_probe_endpoint");
  static const _debugUdpProbeSecret = kDebugMode ? String.fromEnvironment("debug_udp_probe_secret") : "";
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
  final CoreInterface core;

  CoreStatus currentState = const CoreStatus.stopped();
  final statusController = BehaviorSubject<CoreStatus>();
  final logController = BehaviorSubject<List<LogMessage>>();
  final CallOptions? grpcOptions = null; //CallOptions(timeout: const Duration(milliseconds: 10000));
  final Map<String, StreamSubscription?> subscriptions = {};
  final Map<String, int> _listenerReconnectAttempt = {};
  final Map<String, Future<void>> _statusListenerRecoveryByKey = {};
  int _stoppingStatusWatchdogGeneration = 0;
  ({int generation, Future<Either<String, Unit>> future})? _stopInFlight;
  late final SessionGenerationGate _sessionGeneration = SessionGenerationGate(
    onStale: (stale, current, source) {
      loggy.warning(
        vpnDiagnosticEvent("stale_callback_ignored", stale, details: "current_generation=$current source=$source"),
      );
    },
  );
  final SerialLifecycleQueue _lifecycleQueue = SerialLifecycleQueue();
  late final StreamSubscription<VpnSessionSnapshot> _platformSnapshotSubscription;
  Future<void> _platformSnapshotTail = Future<void>.value();
  VpnSessionSnapshot? _latestPlatformSnapshot;
  final BehaviorSubject<VpnSessionSnapshot> _authoritativeSnapshotController = BehaviorSubject<VpnSessionSnapshot>();
  _CoreLifecycleState _lifecycleState = _CoreLifecycleState.stopped;
  int _connectedGeneration = 0;
  int _closeFrontOperationSequence = 0;
  int _appResumeSequence = 0;
  int _foregroundLifecycleEpoch = 0;
  final Map<TransportCloseIntent, int> _activeTransportTeardownIntents = {};
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

  void _queuePlatformSessionSnapshot(VpnSessionSnapshot snapshot) {
    final previous = _platformSnapshotTail;
    _platformSnapshotTail = () async {
      try {
        await previous;
      } catch (_) {
        // A failed preference write must not permanently break the bridge.
      }
      try {
        await _applyPlatformSessionSnapshot(snapshot);
      } catch (error, stackTrace) {
        loggy.warning("failed to apply Android VPN snapshot", error, stackTrace);
      }
    }();
  }

  Future<void> _applyPlatformSessionSnapshot(VpnSessionSnapshot snapshot) async {
    if (snapshot.generation < _sessionGeneration.current) {
      loggy.warning(
        vpnDiagnosticEvent(
          "stale_callback_ignored",
          snapshot.generation,
          details:
              "current_generation=${_sessionGeneration.current} source=android_snapshot_bridge "
              "phase=${snapshot.phase.name}",
        ),
      );
      return;
    }
    _sessionGeneration.advanceTo(snapshot.generation);
    _latestPlatformSnapshot = snapshot;
    _publishAuthoritativeSnapshot(snapshot);

    // Synchronize explicit platform stops and platform-owned starts before
    // their status reaches ConnectionNotifier. Persistence is best-effort and
    // can never suppress the authoritative state event.
    await _syncRunningIntentFromPlatformSnapshot(snapshot);

    final authoritative = snapshot.toCoreStatus();
    if (snapshot.provesConnected) {
      _connectedGeneration = snapshot.generation;
    } else if (authoritative is CoreStopped) {
      _connectedGeneration = 0;
    }
    currentState = authoritative;
    _syncLifecycleFromCoreStatus(
      authoritative,
      reason: "Android snapshot/${snapshot.phase.name}/${snapshot.stopSource.name}",
    );
    if (!statusController.isClosed) {
      statusController.add(authoritative);
    }
    loggy.info(
      vpnDiagnosticEvent(
        "vpn_snapshot_applied",
        snapshot.generation,
        details:
            "phase=${snapshot.phase.name} requested_action=${snapshot.requestedAction} "
            "stop_source=${snapshot.stopSource.name}",
      ),
    );
  }

  bool _platformConfirmsStopped(int generation) {
    final snapshot = _latestPlatformSnapshot;
    return snapshot != null && snapshot.generation == generation && snapshot.phase == VpnSessionPhase.disconnected;
  }

  Future<void> _syncRunningIntentFromPlatformSnapshot(VpnSessionSnapshot snapshot) async {
    final running = snapshot.provesConnected
        ? true
        : snapshot.isExternalIntentionalStop
        ? false
        : null;
    if (running == null) return;
    try {
      await ref.read(Preferences.startedByUser.notifier).update(running).timeout(const Duration(seconds: 1));
    } catch (error, stackTrace) {
      loggy.warning("failed to persist platform running intent", error, stackTrace);
    }
  }

  Future<CoreStatus?> resyncFromPlatform(String source, {bool publish = false}) async {
    final authoritative = await core.resyncSessionStatus();
    final snapshot = core.authoritativeSessionSnapshot;
    if (snapshot != null) {
      _sessionGeneration.advanceTo(snapshot.generation);
      _latestPlatformSnapshot = snapshot;
      _publishAuthoritativeSnapshot(snapshot);
      await _syncRunningIntentFromPlatformSnapshot(snapshot);
    } else {
      _sessionGeneration.advanceTo(core.authoritativeSessionGeneration);
    }
    if (authoritative == null) return null;
    if (publish) {
      currentState = authoritative;
      _syncLifecycleFromCoreStatus(authoritative, reason: "platform resync/$source");
      statusController.add(authoritative);
    }
    loggy.info(
      vpnDiagnosticEvent(
        "vpn_snapshot_resync",
        _sessionGeneration.current,
        details: "source=$source status=${authoritative.runtimeType} published=$publish",
      ),
    );
    return authoritative;
  }

  VpnSessionSnapshot? get authoritativeSessionSnapshot => _latestPlatformSnapshot ?? core.authoritativeSessionSnapshot;

  /// Refreshes the native snapshot cache without publishing [CoreStatus] or
  /// synchronizing persisted running intent. Telemetry classification must be
  /// observational and must not mutate lifecycle state merely to obtain
  /// authoritative evidence.
  Future<VpnSessionSnapshot?> readAuthoritativeSessionSnapshot() async {
    await core.resyncSessionStatus();
    return core.authoritativeSessionSnapshot;
  }

  Stream<VpnSessionSnapshot> watchAuthoritativeSessionSnapshots() => _authoritativeSnapshotController.stream;

  Future<VpnSessionSnapshot?> resyncSessionSnapshot(String source) async {
    await resyncFromPlatform(source);
    return authoritativeSessionSnapshot;
  }

  void _publishAuthoritativeSnapshot(VpnSessionSnapshot snapshot) {
    if (_authoritativeSnapshotController.isClosed) return;
    if (_authoritativeSnapshotController.hasValue) {
      final previous = _authoritativeSnapshotController.value;
      if (previous.runtimeEpoch == snapshot.runtimeEpoch &&
          previous.generation == snapshot.generation &&
          previous.sequenceNumber == snapshot.sequenceNumber &&
          previous.snapshotVersion == snapshot.snapshotVersion) {
        return;
      }
    }
    _authoritativeSnapshotController.add(snapshot);
  }

  int beginVpnOperation(String source) {
    final generation = _sessionGeneration.next();
    _connectedGeneration = 0;
    _transitionLifecycle(_CoreLifecycleState.starting, reason: "$source requested");
    statusController.add(currentState = const CoreStatus.starting());
    final operationEvent = vpnDiagnosticEvent(
      source == "mode_switch" ? "mode_switch_requested" : "vpn_session_start",
      generation,
      details:
          "operation_generation=$generation current_generation=${_sessionGeneration.current} "
          "session_state=${_lifecycleState.name} source=$source reason=requested",
    );
    if (source == "mode_switch") {
      loggy.warning(operationEvent);
    } else {
      loggy.info(operationEvent);
    }
    return generation;
  }

  bool isVpnOperationCurrent(int generation, {String source = "external_operation_guard"}) =>
      _sessionGeneration.isCurrent(generation, source: source);

  bool _isStaleOperation(int generation, String source, {Object? error}) {
    if (_sessionGeneration.classifyCompletion(generation, source: source) == SessionCompletionDisposition.current) {
      return false;
    }
    loggy.warning(
      vpnDiagnosticEvent(
        error == null ? "stale_completion_ignored" : "stale_exception_ignored",
        generation,
        details:
            "operation_generation=$generation current_generation=${_sessionGeneration.current} "
            "session_state=${_lifecycleState.name} source=$source "
            "reason=${error == null ? "superseded" : error.runtimeType}",
      ),
    );
    return true;
  }

  CoreStatus _gateTerminalStatus(CoreStatus next, int generation, String source) {
    if (next is! CoreStarted || generation == _connectedGeneration) return next;
    loggy.warning(
      vpnDiagnosticEvent(
        "terminal_state_blocked",
        generation,
        details:
            "operation_generation=$generation current_generation=${_sessionGeneration.current} "
            "session_state=${_lifecycleState.name} source=$source reason=start_gate_incomplete",
      ),
    );
    return const CoreStatus.starting();
  }

  Future<CoreStatus> _applyCoreStatusFromListener(String key, CoreStatus next, int generation) async {
    if (!_sessionGeneration.isCurrent(generation, source: "coreInfoListener[$key]")) {
      return currentState;
    }
    final gatedNext = _gateTerminalStatus(next, generation, "coreInfoListener[$key]");
    // A local control listener cannot declare the platform VPN stopped unless
    // the background endpoint or authoritative native session confirms it.
    if (gatedNext is CoreStopped && _lifecycleState == _CoreLifecycleState.started) {
      final backgroundState = await _probeBackgroundCoreState();
      final decision = classifyLocalControlStatus(
        backgroundState: backgroundState,
        nativeProvesConnected: _nativeSnapshotProvesCurrentConnected(),
        nativeProvesStopped: _nativeSnapshotProvesCurrentStopped(),
      );
      if (decision != LocalControlStatusDecision.publishStopped) {
        loggy.warning("ignore unconfirmed stopped from coreInfoListener[$key]: background=${backgroundState.name}");
        return currentState;
      }
    }
    currentState = gatedNext;
    _syncLifecycleFromCoreStatus(currentState, reason: "coreInfoListener[$key]");
    statusController.add(currentState);
    if (gatedNext is CoreStopping) {
      _scheduleStoppingStatusWatchdog("coreInfoListener[$key]");
    }
    return currentState;
  }

  Future<T> _enqueueLifecycle<T>(String opName, Future<T> Function() action) {
    loggy.debug("lifecycle queue: enqueue $opName (state=${_lifecycleState.name})");
    return _lifecycleQueue.enqueue(() async {
      loggy.debug("lifecycle queue: begin $opName (state=${_lifecycleState.name})");
      try {
        return await action();
      } finally {
        loggy.debug("lifecycle queue: end $opName (state=${_lifecycleState.name})");
      }
    });
  }

  Duration _listenerReconnectDelay(String key) {
    final attempt = (_listenerReconnectAttempt[key] ?? 0) + 1;
    _listenerReconnectAttempt[key] = attempt;
    final exp = min(_listenerBackoffMaxMs, _listenerBackoffBaseMs * (1 << min(attempt - 1, 4)));
    final jitter = Random().nextInt(max(1, exp ~/ 4));
    return Duration(milliseconds: exp + jitter);
  }

  Future<bool> _scheduleListenerReconnect(String key, Future<void> Function() starter) async {
    if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) {
      loggy.debug("listener reconnect skipped [$key]: lifecycle=${_lifecycleState.name}");
      return false;
    }
    final delay = _listenerReconnectDelay(key);
    loggy.debug("listener reconnect scheduled [$key] in ${delay.inMilliseconds}ms");
    await Future<void>.delayed(delay);
    if (!core.isInitialized()) return false;
    if (_lifecycleState == _CoreLifecycleState.stopping || _lifecycleState == _CoreLifecycleState.stopped) {
      return false;
    }
    if (subscriptions.containsKey(key)) return true;
    try {
      await starter();
      return true;
    } catch (e, st) {
      loggy.warning("listener reconnect failed [$key]", e, st);
      return false;
    }
  }

  TransportCloseIntent get _activeTransportTeardownIntent {
    for (final intent in const [
      TransportCloseIntent.restartReplacement,
      TransportCloseIntent.stop,
      TransportCloseIntent.foregroundClose,
    ]) {
      if ((_activeTransportTeardownIntents[intent] ?? 0) > 0) return intent;
    }
    return TransportCloseIntent.none;
  }

  Future<T> _withinExpectedTransportTeardown<T>(TransportCloseIntent intent, Future<T> Function() action) async {
    _activeTransportTeardownIntents.update(intent, (count) => count + 1, ifAbsent: () => 1);
    try {
      return await action();
    } finally {
      final remaining = (_activeTransportTeardownIntents[intent] ?? 1) - 1;
      if (remaining == 0) {
        _activeTransportTeardownIntents.remove(intent);
      } else {
        _activeTransportTeardownIntents[intent] = remaining;
      }
    }
  }

  void _recordTransportCloseOutcome({
    required String source,
    required int generation,
    required TransportCloseDisposition disposition,
    required Object error,
    StackTrace? stackTrace,
    bool reportIncident = true,
  }) {
    final event = vpnDiagnosticEvent(
      "grpc_transport_outcome",
      generation,
      details:
          "source=$source outcome=${disposition.name} error_type=${error.runtimeType} "
          "native_phase=${authoritativeSessionSnapshot?.phase.name ?? "none"}",
    );
    if (disposition == TransportCloseDisposition.realFailure && reportIncident) {
      loggy.error(event, error, stackTrace);
    } else {
      loggy.warning(event, error);
    }
  }

  Future<void> _handleListenerTransportClose({
    required String key,
    required int generation,
    required Object error,
    required TransportCloseIntent teardownIntent,
    required Future<void> Function() reconnect,
  }) async {
    if (error is! GrpcError || !_isTransientGrpcTransportClose(error)) {
      _recordTransportCloseOutcome(
        source: "${key}_listener",
        generation: generation,
        disposition: TransportCloseDisposition.realFailure,
        error: error,
      );
      unawaited(_scheduleListenerReconnect(key, reconnect));
      return;
    }

    if (teardownIntent != TransportCloseIntent.none) {
      final disposition = classifyTransportClose(
        intent: teardownIntent,
        stage: TransportCloseStage.teardown,
        operationGeneration: generation,
        operationCurrent: _sessionGeneration.isCurrent(generation, source: "${key}_teardown_close"),
        backgroundCoreActive: false,
        controlRecoverySucceeded: false,
        nativeSnapshot: authoritativeSessionSnapshot,
        explicitFailure: false,
      );
      _recordTransportCloseOutcome(
        source: "${key}_listener",
        generation: generation,
        disposition: disposition,
        error: error,
      );
      unawaited(_scheduleListenerReconnect(key, reconnect));
      return;
    }

    // Start the existing recovery immediately. Telemetry observes its result
    // but must never delay it behind the background reachability probe.
    final controlRecovery = _scheduleListenerReconnect(key, reconnect);
    final backgroundCoreActive = await _isBackgroundCoreReachable();
    final controlRecoverySucceeded = await controlRecovery;
    final disposition = classifyTransportClose(
      intent: TransportCloseIntent.none,
      stage: TransportCloseStage.listener,
      operationGeneration: generation,
      operationCurrent: _sessionGeneration.isCurrent(generation, source: "${key}_transport_outcome"),
      backgroundCoreActive: backgroundCoreActive,
      controlRecoverySucceeded: controlRecoverySucceeded,
      nativeSnapshot: authoritativeSessionSnapshot,
      explicitFailure: false,
    );
    _recordTransportCloseOutcome(
      source: "${key}_listener",
      generation: generation,
      disposition: disposition,
      error: error,
    );
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

    final backgroundState = await _probeBackgroundCoreState();
    final decision = classifyLocalControlStatus(
      backgroundState: backgroundState,
      nativeProvesConnected: _nativeSnapshotProvesCurrentConnected(),
      nativeProvesStopped: _nativeSnapshotProvesCurrentStopped(),
    );
    if (decision == LocalControlStatusDecision.publishStopped) {
      loggy.warning("$reason: background core is down, forcing stopped", error);
      await _deleteCoreCurrentConfigSnapshot();
      _transitionLifecycle(_CoreLifecycleState.stopped, reason: reason);
      _clearRuntimeOutboundSnapshot(reason);
      statusController.add(currentState = const CoreStatus.stopped());
      return;
    }

    if (decision == LocalControlStatusDecision.preserve) {
      loggy.warning("$reason: background state is inconclusive, preserving stopping", error);
      return;
    }

    loggy.warning("$reason: background or native session is still active, forcing started", error);
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

  void recordAppResume() {
    _appResumeSequence++;
    _foregroundLifecycleEpoch++;
  }

  Future<void> init() async {
    _foregroundLifecycleEpoch++;
    await _deleteCoreCurrentConfigSnapshot();
    await setup()
        .mapLeft((e) {
          loggy.error(e);
          if (PlatformUtils.isIOS) return;
          // Failure to reconstruct the foreground control channel is not
          // evidence that the platform-owned VPN tunnel stopped.
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
      _foregroundLifecycleEpoch++;
      if (_useMockCore) {
        if (_lifecycleState != _CoreLifecycleState.starting && _lifecycleState != _CoreLifecycleState.stopping) {
          currentState = const CoreStatus.stopped();
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "mock setup");
          statusController.add(currentState);
        }
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

        if (setupResponse.isNotEmpty) return left(setupResponse);

        await startListeningLogs("fg", core.fgClient);
        // await startListeningStatus("fg", core.fgClient);
        final backgroundState = await _probeBackgroundCoreState(attempts: PlatformUtils.isIOS ? 8 : 1);
        final bgActive = backgroundState == CloseFrontBackgroundState.active;
        if (bgActive && !core.isSingleChannel()) {
          await startListeningLogs("bg", core.bgClient);
        }
        final lifecycleIntentReserved =
            _lifecycleState == _CoreLifecycleState.starting || _lifecycleState == _CoreLifecycleState.stopping;
        var publishSetupStatus = core.isSingleChannel();
        if (!core.isSingleChannel() && !lifecycleIntentReserved) {
          final decision = classifyLocalControlStatus(
            backgroundState: backgroundState,
            nativeProvesConnected: _nativeSnapshotProvesCurrentConnected(),
            nativeProvesStopped: _nativeSnapshotProvesCurrentStopped(),
          );
          switch (decision) {
            case LocalControlStatusDecision.publishStarted:
              currentState = const CoreStatus.started();
              _transitionLifecycle(_CoreLifecycleState.started, reason: "setup background/native state");
              publishSetupStatus = true;
            case LocalControlStatusDecision.publishStopped:
              currentState = const CoreStatus.stopped();
              _transitionLifecycle(_CoreLifecycleState.stopped, reason: "setup background/native state");
              publishSetupStatus = true;
            case LocalControlStatusDecision.preserve:
              loggy.warning("setup background probe was inconclusive; preserving current VPN status");
          }
        }
        if (!lifecycleIntentReserved && publishSetupStatus) {
          statusController.add(currentState);
        } else {
          loggy.debug("setup background probe preserved reserved lifecycle=${_lifecycleState.name}");
        }
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

      if (await _shouldDeferCoreOptionsUntilStart()) {
        loggy.info("core options queued until background core starts");
        return right(unit);
      }

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

  Future<bool> _shouldDeferCoreOptionsUntilStart() async {
    if (_useMockCore || core.isSingleChannel()) return false;

    final stoppedOrStopping =
        _lifecycleState == _CoreLifecycleState.stopped ||
        _lifecycleState == _CoreLifecycleState.stopping ||
        currentState is CoreStopped ||
        currentState is CoreStopping;
    if (!stoppedOrStopping) return false;

    final bgReachable = await _isBackgroundCoreReachable(
      attempts: PlatformUtils.isIOS ? 2 : 1,
      retryDelay: const Duration(milliseconds: 150),
    );
    return !bgReachable;
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

  Future<bool> _isBackgroundCoreReachable({
    int attempts = 1,
    Duration retryDelay = const Duration(milliseconds: 250),
  }) async {
    return await _probeBackgroundCoreState(attempts: attempts, retryDelay: retryDelay) ==
        CloseFrontBackgroundState.active;
  }

  Future<CloseFrontBackgroundState> _probeBackgroundCoreState({
    int attempts = 1,
    Duration retryDelay = const Duration(milliseconds: 250),
  }) async {
    if (!core.isInitialized()) return CloseFrontBackgroundState.unknown;
    if (core.isSingleChannel()) return CloseFrontBackgroundState.active;

    var lastState = CloseFrontBackgroundState.unknown;
    final maxAttempts = max(1, attempts);
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      PortProbeObservation? observation;
      try {
        final active = await core.isActiveBg(onPortProbe: (value) => observation = value);
        lastState = closeFrontBackgroundState(singleChannel: false, backgroundActive: active, observation: observation);
      } catch (_) {
        lastState = CloseFrontBackgroundState.unknown;
      }
      if (lastState == CloseFrontBackgroundState.active) return lastState;
      if (attempt < maxAttempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    return lastState;
  }

  bool _nativeSnapshotProvesCurrentConnected() {
    final snapshot = authoritativeSessionSnapshot;
    return snapshot != null && snapshot.generation == _sessionGeneration.current && snapshot.provesConnected;
  }

  bool _nativeSnapshotProvesCurrentStopped() {
    final snapshot = authoritativeSessionSnapshot;
    return snapshot != null &&
        snapshot.generation == _sessionGeneration.current &&
        (snapshot.phase == VpnSessionPhase.disconnected || snapshot.phase == VpnSessionPhase.failed);
  }

  Future<VpnSessionSnapshot?> _refreshStartupSnapshot(int generation, String source) async {
    if (!PlatformUtils.isAndroid) return authoritativeSessionSnapshot;
    try {
      return await readAuthoritativeSessionSnapshot();
    } catch (error, stackTrace) {
      loggy.warning(
        vpnDiagnosticEvent(
          "startup_snapshot_unavailable",
          generation,
          details: "source=$source error_type=${error.runtimeType}",
        ),
        error,
        stackTrace,
      );
      return authoritativeSessionSnapshot;
    }
  }

  StartupOutcomeDisposition _classifyStartupFailure({
    required int generation,
    required StartupFailureSignal signal,
    BackgroundSetupFailure backgroundSetupFailure = BackgroundSetupFailure.none,
    VpnSessionSnapshot? nativeSnapshot,
    bool controlRecoverySucceeded = false,
  }) {
    return classifyStartupOutcome(
      StartupOutcomeEvidence(
        operationGeneration: generation,
        operationCurrent: _sessionGeneration.isCurrent(generation, source: "startup_outcome"),
        signal: signal,
        backgroundSetupFailure: backgroundSetupFailure,
        nativeSnapshot: nativeSnapshot,
        controlRecoverySucceeded: controlRecoverySucceeded,
      ),
    );
  }

  void _recordStartupOutcome({
    required int generation,
    required StartupFailureSignal signal,
    required StartupOutcomeDisposition disposition,
    BackgroundSetupFailure backgroundSetupFailure = BackgroundSetupFailure.none,
    VpnSessionSnapshot? nativeSnapshot,
  }) {
    loggy.warning(
      vpnDiagnosticEvent(
        "startup_outcome",
        generation,
        details:
            "signal=${signal.name} outcome=${disposition.name} "
            "background_setup=${backgroundSetupFailure.name} "
            "native_generation=${nativeSnapshot?.generation ?? 0} "
            "native_phase=${nativeSnapshot?.phase.name ?? "none"} "
            "failure_code=${nativeSnapshot?.failureCode.isNotEmpty == true ? nativeSnapshot!.failureCode : "none"}",
      ),
    );
  }

  ConnectionFailure _startupConnectionFailure({
    required int generation,
    required StartupOutcomeDisposition disposition,
    required StartupFailureSignal signal,
    BackgroundSetupFailure backgroundSetupFailure = BackgroundSetupFailure.none,
    VpnSessionSnapshot? nativeSnapshot,
  }) {
    final detail =
        "category=${disposition.name} signal=${signal.name} generation=$generation "
        "background_setup=${backgroundSetupFailure.name} "
        "native_phase=${nativeSnapshot?.phase.name ?? "none"} "
        "native_failure=${nativeSnapshot?.failureCode.isNotEmpty == true ? nativeSnapshot!.failureCode : "none"}";
    if (disposition == StartupOutcomeDisposition.controlChannelFailure) {
      return ConnectionFailure.backgroundCoreNotAvailable("background control startup failed [$detail]");
    }
    return ConnectionFailure.unexpected("core startup failed [$detail]");
  }

  bool _completeNonIncidentStartupOutcome(int generation, StartupOutcomeDisposition disposition, String reason) {
    if (startupOutcomeIsIncident(disposition)) return false;
    if (disposition == StartupOutcomeDisposition.recovered &&
        _sessionGeneration.isCurrent(generation, source: "startup_recovered/$reason")) {
      _connectedGeneration = generation;
      _transitionLifecycle(_CoreLifecycleState.started, reason: reason);
      statusController.add(currentState = const CoreStatus.started());
    }
    return true;
  }

  Future<void> _cleanupFailedStartup(
    int generation,
    String reason, {
    CoreStatus terminalStatus = const CoreStatus.stopped(),
  }) async {
    try {
      await core.stop(generation: generation).timeout(const Duration(seconds: 14), onTimeout: () => false);
    } catch (error, stackTrace) {
      loggy.warning("failed startup cleanup did not complete [$reason]", error, stackTrace);
    }
    if (!_sessionGeneration.isCurrent(generation, source: "startup_cleanup/$reason")) return;
    _transitionLifecycle(_CoreLifecycleState.stopped, reason: reason);
    statusController.add(currentState = terminalStatus);
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
    const udpProbeEnabled = _udpProbeEnabled || _debugUdpProbeEnabled;
    const udpProbeSecret = _udpProbeSecret != "" ? _udpProbeSecret : _debugUdpProbeSecret;
    if (udpProbeEnabled) {
      if (udpProbeSecret.isEmpty) {
        map["udp-probe-enabled"] = false;
        loggy.warning("UDP probe requested without secret; keeping probe disabled");
      } else {
        map["udp-probe-enabled"] = true;
        map["udp-probe-endpoint"] = _udpProbeEndpoint.isNotEmpty
            ? _udpProbeEndpoint
            : _debugUdpProbeEndpoint.isNotEmpty
            ? _debugUdpProbeEndpoint
            : "udp-probe.zeon-vps.link:8443";
        map["udp-probe-secret"] = udpProbeSecret;
        map["udp-probe-count"] = _debugUdpProbeEnabled ? _debugUdpProbeCount : 3;
        map["udp-probe-size"] = _debugUdpProbeEnabled ? _debugUdpProbeSize : 128;
        map["udp-probe-interval-ms"] = _debugUdpProbeEnabled ? _debugUdpProbeIntervalMs : 40;
        map["udp-probe-timeout-ms"] = _debugUdpProbeEnabled ? _debugUdpProbeTimeoutMs : 750;
        map["udp-probe-cooldown-sec"] = _debugUdpProbeEnabled ? _debugUdpProbeCooldownSec : 60;
        map["udp-probe-top-n"] = _debugUdpProbeEnabled ? _debugUdpProbeTopN : 3;
      }
    }
    final runtime = await _readRuntimeNetworkInfo();
    map["network-transport-type"] = runtime.$1;
    map["network-interface-mtu"] = runtime.$2;

    final userRules = await _loadUserRouteRulesFromProto();
    final configuredRules = (map["rules"] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((rule) => Map<String, dynamic>.from(rule))
        .toList();
    final rulePlan = MobileApiProxyRoute.planCoreRules(configuredRules: configuredRules, userRules: userRules);
    map["rules"] = rulePlan.priorityRules;
    map["profile-rules"] = rulePlan.profileRules;

    loggy.info(
      "core options prepared: full-config=$fullConfig transport=${runtime.$1} iface-mtu=${runtime.$2} user-rules=${(map["rules"] as List?)?.length ?? 0}",
    );
    return map;
  }

  @visibleForTesting
  Future<Map<String, dynamic>> buildCoreOptionsPayloadForTesting(SingboxConfigOption options) {
    return _buildCoreOptionsPayload(options);
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

  TaskEither<ConnectionFailure, Unit> start(
    String path,
    String name,
    bool disableMemoryLimit, {
    required int generation,
  }) {
    return TaskEither(() {
      return _enqueueLifecycle("start", () async {
        if (_isStaleOperation(generation, "start_queue_entry")) return right(unit);
        try {
          await core.setSessionGeneration(generation);
        } catch (e) {
          if (_isStaleOperation(generation, "start_set_generation", error: e)) return right(unit);
          rethrow;
        }
        if (_useMockCore) {
          _transitionLifecycle(_CoreLifecycleState.starting, reason: "mock start");
          statusController.add(currentState = const CoreStatus.starting());
          await Future<void>.delayed(const Duration(milliseconds: 180));
          if (_isStaleOperation(generation, "mock_start")) return right(unit);
          _connectedGeneration = generation;
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

        final BackgroundSetupResult backgroundSetup;
        try {
          backgroundSetup = await core.setupBackground(path, name, generation: generation);
        } catch (e, st) {
          if (_isStaleOperation(generation, "background_setup", error: e)) return right(unit);
          final nativeSnapshot = await _refreshStartupSnapshot(generation, "background_setup_exception");
          final disposition = _classifyStartupFailure(
            generation: generation,
            signal: StartupFailureSignal.unknown,
            nativeSnapshot: nativeSnapshot,
          );
          _recordStartupOutcome(
            generation: generation,
            signal: StartupFailureSignal.unknown,
            disposition: disposition,
            nativeSnapshot: nativeSnapshot,
          );
          if (_completeNonIncidentStartupOutcome(generation, disposition, "background setup exception recovered")) {
            return right(unit);
          }
          await _deleteCoreCurrentConfigSnapshot();
          loggy.warning("failed to setup background core", e, st);
          await _cleanupFailedStartup(generation, "background setup error");
          return left(
            _startupConnectionFailure(
              generation: generation,
              disposition: disposition,
              signal: StartupFailureSignal.unknown,
              nativeSnapshot: nativeSnapshot,
            ),
          );
        }
        if (_isStaleOperation(generation, "background_setup")) return right(unit);
        if (!backgroundSetup.isReady) {
          final nativeSnapshot = backgroundSetup.nativeSnapshot ?? authoritativeSessionSnapshot;
          final disposition = _classifyStartupFailure(
            generation: generation,
            signal: StartupFailureSignal.backgroundSetup,
            backgroundSetupFailure: backgroundSetup.failure,
            nativeSnapshot: nativeSnapshot,
          );
          _recordStartupOutcome(
            generation: generation,
            signal: StartupFailureSignal.backgroundSetup,
            disposition: disposition,
            backgroundSetupFailure: backgroundSetup.failure,
            nativeSnapshot: nativeSnapshot,
          );
          if (_completeNonIncidentStartupOutcome(generation, disposition, "background setup recovered")) {
            return right(unit);
          }
          await _deleteCoreCurrentConfigSnapshot();
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "background setup failed");
          statusController.add(currentState = const CoreStatus.stopped());
          return left(
            _startupConnectionFailure(
              generation: generation,
              disposition: disposition,
              signal: StartupFailureSignal.backgroundSetup,
              backgroundSetupFailure: backgroundSetup.failure,
              nativeSnapshot: nativeSnapshot,
            ),
          );
        }

        if (!core.isSingleChannel()) {
          await startListeningLogs("bg", core.bgClient);
          await startListeningStatus("bg", core.bgClient, generation: generation);
        }

        final optionsResult = await _applyLatestCoreOptionsToBackground("start");
        if (optionsResult.isLeft()) {
          final nativeSnapshot = await _refreshStartupSnapshot(generation, "background_options_failed");
          final disposition = _classifyStartupFailure(
            generation: generation,
            signal: StartupFailureSignal.configuration,
            nativeSnapshot: nativeSnapshot,
          );
          _recordStartupOutcome(
            generation: generation,
            signal: StartupFailureSignal.configuration,
            disposition: disposition,
            nativeSnapshot: nativeSnapshot,
          );
          if (_completeNonIncidentStartupOutcome(generation, disposition, "background options recovered")) {
            return right(unit);
          }
          await _deleteCoreCurrentConfigSnapshot();
          await _cleanupFailedStartup(generation, "background options failed");
          return left(
            _startupConnectionFailure(
              generation: generation,
              disposition: disposition,
              signal: StartupFailureSignal.configuration,
              nativeSnapshot: nativeSnapshot,
            ),
          );
        }

        try {
          loggy.info(vpnDiagnosticEvent("core_start_requested", generation, details: "owner=flutter"));
          final res = await core.bgClient.start(
            StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit),
          );
          if (_isStaleOperation(generation, "core_start_result")) return right(unit);
          ref.read(coreRestartSignalProvider.notifier).restart();
          if (res.messageType == MessageType.ALREADY_STARTED) {
            loggy.warning(vpnDiagnosticEvent("core_already_started_conflict", generation));
            await core.stop(generation: generation);
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "duplicate native core");
            statusController.add(currentState = const CoreStatus.stopped());
            return left(const ConnectionFailure.unexpected("core is already started by another session"));
          }
          if (res.messageType != MessageType.EMPTY) {
            final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_start_response");
            final disposition = _classifyStartupFailure(
              generation: generation,
              signal: StartupFailureSignal.coreResponse,
              nativeSnapshot: nativeSnapshot,
            );
            _recordStartupOutcome(
              generation: generation,
              signal: StartupFailureSignal.coreResponse,
              disposition: disposition,
              nativeSnapshot: nativeSnapshot,
            );
            if (_completeNonIncidentStartupOutcome(generation, disposition, "core response recovered")) {
              return right(unit);
            }
            loggy.warning(
              vpnDiagnosticEvent(
                "core_start_failure",
                generation,
                details: "error=core_response_${res.messageType.name}",
              ),
            );
            final alert = isVpnPermissionDenied(res.message) ? CoreAlert.requestVPNPermission : CoreAlert.startFailed;
            await core.stop(generation: generation);
            currentState = CoreStatus.stopped(
              alert: alert,
              message: "failed to start core ${res.messageType} ${res.message}",
            );
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "start rejected by core");
            statusController.add(currentState);
            return left(
              alert == CoreAlert.requestVPNPermission
                  ? ConnectionFailure.missingVpnPermission(res.message)
                  : _startupConnectionFailure(
                      generation: generation,
                      disposition: disposition,
                      signal: StartupFailureSignal.coreResponse,
                      nativeSnapshot: nativeSnapshot,
                    ),
            );
          }
          await core.markCoreStarted(generation);
          if (_isStaleOperation(generation, "mark_core_started_result")) return right(unit);
          _connectedGeneration = generation;
          loggy.info(vpnDiagnosticEvent("core_start_success", generation));
          await _emitRedactedEffectiveConfig(generation, "start");
          await _logRuntimeIndicators(generation, "core_start_success");
        } on GrpcError catch (e, st) {
          if (_isStaleOperation(generation, "core_start_grpc", error: e)) return right(unit);
          ref.read(coreRestartSignalProvider.notifier).restart();
          if (isVpnPermissionDenied(e)) {
            _recordTransportCloseOutcome(
              source: "core_start",
              generation: generation,
              disposition: TransportCloseDisposition.realFailure,
              error: e,
              stackTrace: st,
              reportIncident: false,
            );
            final message = e.message ?? e.toString();
            await _cleanupFailedStartup(
              generation,
              "vpn permission denied on start",
              terminalStatus: CoreStatus.stopped(alert: CoreAlert.requestVPNPermission, message: message),
            );
            return left(ConnectionFailure.missingVpnPermission(message));
          }
          final transientTransportClose = _isTransientGrpcTransportClose(e);
          if (transientTransportClose &&
              _sessionGeneration.isCurrent(generation, source: "core_start_transport_close")) {
            final backgroundCoreActive = await _isBackgroundCoreReachable(attempts: 3);
            if (backgroundCoreActive) {
              try {
                await core.markCoreStarted(generation);
              } catch (markError, markStackTrace) {
                final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_start_mark_failed");
                final startupDisposition = _classifyStartupFailure(
                  generation: generation,
                  signal: StartupFailureSignal.nativeGate,
                  nativeSnapshot: nativeSnapshot,
                );
                _recordStartupOutcome(
                  generation: generation,
                  signal: StartupFailureSignal.nativeGate,
                  disposition: startupDisposition,
                  nativeSnapshot: nativeSnapshot,
                );
                if (_completeNonIncidentStartupOutcome(
                  generation,
                  startupDisposition,
                  "native start confirmation recovered",
                )) {
                  return right(unit);
                }
                _recordTransportCloseOutcome(
                  source: "core_start_mark_failed",
                  generation: generation,
                  disposition: TransportCloseDisposition.realFailure,
                  error: e,
                  stackTrace: st,
                  reportIncident: false,
                );
                loggy.warning("native recovery confirmation failed after transport close", markError, markStackTrace);
                await _cleanupFailedStartup(generation, "native start confirmation failed");
                return left(
                  _startupConnectionFailure(
                    generation: generation,
                    disposition: startupDisposition,
                    signal: StartupFailureSignal.nativeGate,
                    nativeSnapshot: nativeSnapshot,
                  ),
                );
              }
              if (_isStaleOperation(generation, "core_start_transport_mark")) return right(unit);
              final disposition = classifyTransportClose(
                intent: TransportCloseIntent.none,
                stage: TransportCloseStage.start,
                operationGeneration: generation,
                operationCurrent: true,
                backgroundCoreActive: true,
                controlRecoverySucceeded: true,
                nativeSnapshot: authoritativeSessionSnapshot,
                explicitFailure: false,
              );
              _recordTransportCloseOutcome(
                source: "core_start",
                generation: generation,
                disposition: disposition,
                error: e,
              );
              _transitionLifecycle(_CoreLifecycleState.started, reason: "start transport closed with active bg");
              _connectedGeneration = generation;
              statusController.add(currentState = const CoreStatus.started());
              return right(unit);
            }
          }
          final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_start_grpc_failure");
          final startupDisposition = _classifyStartupFailure(
            generation: generation,
            signal: StartupFailureSignal.grpcTransport,
            nativeSnapshot: nativeSnapshot,
          );
          _recordStartupOutcome(
            generation: generation,
            signal: StartupFailureSignal.grpcTransport,
            disposition: startupDisposition,
            nativeSnapshot: nativeSnapshot,
          );
          if (_completeNonIncidentStartupOutcome(
            generation,
            startupDisposition,
            "native startup recovered after grpc failure",
          )) {
            return right(unit);
          }
          _recordTransportCloseOutcome(
            source: "core_start",
            generation: generation,
            disposition: TransportCloseDisposition.realFailure,
            error: e,
            stackTrace: st,
            reportIncident: false,
          );
          loggy.warning(
            vpnDiagnosticEvent("terminal_failure", generation, details: "phase=core_start error=grpc_${e.code}"),
          );
          await _cleanupFailedStartup(generation, "grpc error on start");
          if (_isMissingWindowsTunPrivilege()) {
            return left(const ConnectionFailure.missingPrivilege());
          }
          return left(
            _startupConnectionFailure(
              generation: generation,
              disposition: startupDisposition,
              signal: StartupFailureSignal.grpcTransport,
              nativeSnapshot: nativeSnapshot,
            ),
          );
        } catch (e, st) {
          if (_isStaleOperation(generation, "core_start_exception", error: e)) return right(unit);
          final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_start_exception");
          final disposition = _classifyStartupFailure(
            generation: generation,
            signal: StartupFailureSignal.unknown,
            nativeSnapshot: nativeSnapshot,
          );
          _recordStartupOutcome(
            generation: generation,
            signal: StartupFailureSignal.unknown,
            disposition: disposition,
            nativeSnapshot: nativeSnapshot,
          );
          if (_completeNonIncidentStartupOutcome(generation, disposition, "core start exception recovered")) {
            return right(unit);
          }
          loggy.warning(vpnDiagnosticEvent("core_start_failure", generation, details: "error=${e.runtimeType}"), e, st);
          await _cleanupFailedStartup(generation, "core start exception");
          return left(
            _startupConnectionFailure(
              generation: generation,
              disposition: disposition,
              signal: StartupFailureSignal.unknown,
              nativeSnapshot: nativeSnapshot,
            ),
          );
        } finally {
          if (_sessionGeneration.isCurrent(generation, source: "core_start_cleanup")) {
            await _deleteCoreCurrentConfigSnapshot();
          }
        }

        if (_isStaleOperation(generation, "start_terminal_publication")) return right(unit);
        _transitionLifecycle(_CoreLifecycleState.started, reason: "start complete");
        statusController.add(currentState = const CoreStatus.started());
        return right(unit);
      });
    });
  }

  TaskEither<String, Unit> prepareVpnConfiguration(
    String path,
    String name,
    bool disableMemoryLimit, {
    required int generation,
  }) {
    return TaskEither(() async {
      if ((!PlatformUtils.isIOS && !PlatformUtils.isAndroid) ||
          (PlatformUtils.isAndroid && ref.read(ConfigOptions.serviceMode) != ServiceMode.tun) ||
          _useMockCore) {
        return right(unit);
      }
      try {
        if (_isStaleOperation(generation, "permission_request")) return right(unit);
        loggy.info(
          vpnDiagnosticEvent(
            "permission_request_started",
            generation,
            details:
                "operation_generation=$generation current_generation=${_sessionGeneration.current} "
                "session_state=${_lifecycleState.name} source=flutter reason=prepare_vpn",
          ),
        );
        await core.setSessionGeneration(generation);
        final prepared = await core.prepareVpn(path, name, disableMemoryLimit, generation: generation);
        if (_isStaleOperation(generation, "permission_result")) return right(unit);
        loggy.info(
          vpnDiagnosticEvent(
            "permission_result_received",
            generation,
            details:
                "operation_generation=$generation current_generation=${_sessionGeneration.current} "
                "session_state=${_lifecycleState.name} source=flutter reason=${prepared ? "granted" : "denied"}",
          ),
        );
        if (!prepared) {
          _transitionLifecycle(_CoreLifecycleState.stopped, reason: "VPN permission denied");
          statusController.add(currentState = const CoreStatus.stopped(alert: CoreAlert.requestVPNPermission));
          return left("missing VPN permission");
        }
        return right(unit);
      } catch (e) {
        if (_isStaleOperation(generation, "permission_exception", error: e)) return right(unit);
        _transitionLifecycle(_CoreLifecycleState.stopped, reason: "VPN permission failure");
        statusController.add(currentState = const CoreStatus.stopped(alert: CoreAlert.requestVPNPermission));
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
    return TaskEither(() {
      if (!force) {
        final existing = _stopInFlight;
        if (existing != null && existing.generation == _sessionGeneration.current) {
          loggy.debug("stop coalesced with the in-flight stop operation [generation=${existing.generation}]");
          return existing.future;
        }
      }
      // Reserve the terminal generation before any platform query or queue
      // wait. This makes Stop immediately supersede an older start/restart.
      final generation = _sessionGeneration.next();
      _connectedGeneration = 0;
      final operation = _stopInternal(force: force, generation: generation);
      if (force) return operation;
      _stopInFlight = (generation: generation, future: operation);
      return operation.whenComplete(() {
        if (identical(_stopInFlight?.future, operation)) {
          _stopInFlight = null;
        }
      });
    });
  }

  Future<Either<String, Unit>> _stopInternal({required bool force, required int generation}) async {
    var operationGeneration = generation;
    var requireNativeStopDespiteLocalState =
        force || _lifecycleState != _CoreLifecycleState.stopped || currentState != const CoreStatus.stopped();
    if (!requireNativeStopDespiteLocalState && !core.supportsPreemptivePlatformStop) {
      CoreStatus? authoritative;
      try {
        authoritative = await core.resyncSessionStatus().timeout(const Duration(seconds: 2), onTimeout: () => null);
        _sessionGeneration.advanceTo(core.authoritativeSessionGeneration);
      } catch (error, stackTrace) {
        loggy.warning("stop preflight snapshot failed; issuing an idempotent native stop", error, stackTrace);
      }
      if (authoritative is CoreStopped) {
        loggy.debug("stop ignored: platform confirms already stopped");
        return right(unit);
      }
      if (!core.supportsPreemptivePlatformStop && _isStaleOperation(operationGeneration, "stop_preflight")) {
        return right(unit);
      }
      requireNativeStopDespiteLocalState = true;
      loggy.warning(
        "local lifecycle was stopped but platform state is "
        "${authoritative?.runtimeType ?? "unavailable"}; stopping",
      );
    }
    if (!core.supportsPreemptivePlatformStop &&
        _isStaleOperation(operationGeneration, "stop_before_platform_request")) {
      return right(unit);
    }
    if (!_useMockCore && core.supportsPreemptivePlatformStop) {
      _transitionLifecycle(_CoreLifecycleState.stopping, reason: "preemptive Android stop requested");
      statusController.add(currentState = const CoreStatus.stopping());
      try {
        final acceptedGeneration = await core
            .requestPlatformStop(generation: operationGeneration)
            .timeout(const Duration(seconds: 3));
        if (acceptedGeneration > operationGeneration) {
          final existing = _stopInFlight;
          if (existing != null && existing.generation == operationGeneration) {
            _stopInFlight = (generation: acceptedGeneration, future: existing.future);
          }
          operationGeneration = acceptedGeneration;
          _sessionGeneration.advanceTo(acceptedGeneration);
        }
        requireNativeStopDespiteLocalState = true;
      } catch (error, stackTrace) {
        // The serialized cleanup below retries the idempotent native stop.
        loggy.warning("preemptive Android VPN stop request failed; queued cleanup will retry", error, stackTrace);
      }
    }
    return await _enqueueLifecycle("stop", () async {
      if (_isStaleOperation(operationGeneration, "stop_queue_entry")) return right(unit);
      try {
        await core.setSessionGeneration(operationGeneration);
      } catch (error) {
        if (_isStaleOperation(operationGeneration, "stop_set_generation", error: error)) return right(unit);
        loggy.error("failed to synchronize native stop generation", error);
        return left("failed to synchronize VPN stop generation (${error.runtimeType})");
      }
      if (_useMockCore) {
        _transitionLifecycle(_CoreLifecycleState.stopping, reason: "mock stop");
        statusController.add(currentState = const CoreStatus.stopping());
        await Future<void>.delayed(const Duration(milliseconds: 120));
        _transitionLifecycle(_CoreLifecycleState.stopped, reason: "mock stop complete");
        statusController.add(currentState = const CoreStatus.stopped());
        return right(unit);
      }

      if (!requireNativeStopDespiteLocalState &&
          _lifecycleState == _CoreLifecycleState.stopped &&
          currentState == const CoreStatus.stopped()) {
        loggy.debug("stop ignored: already stopped");
        return right(unit);
      }

      var platformStopped = _platformConfirmsStopped(operationGeneration);
      if (!platformStopped) {
        _transitionLifecycle(_CoreLifecycleState.stopping, reason: "stop requested");
        statusController.add(currentState = const CoreStatus.stopping());
      }
      loggy.debug("stopping");

      var errMsg = "";
      GrpcError? grpcStopError;
      try {
        await _withinExpectedTransportTeardown(TransportCloseIntent.stop, () async {
          await _logRuntimeIndicators(operationGeneration, "before_stop");
          await _closeSessionListeners(operationGeneration);
          platformStopped = _platformConfirmsStopped(operationGeneration);
          if (!platformStopped) {
            await core.bgClient.stop(Empty(), options: CallOptions(timeout: const Duration(seconds: 3)));
          }
        });
      } on GrpcError catch (e) {
        if (_isTransientGrpcTransportClose(e)) {
          _recordTransportCloseOutcome(
            source: "core_stop",
            generation: operationGeneration,
            disposition: classifyTransportClose(
              intent: TransportCloseIntent.stop,
              stage: TransportCloseStage.teardown,
              operationGeneration: operationGeneration,
              operationCurrent: _sessionGeneration.isCurrent(operationGeneration, source: "core_stop_transport_close"),
              backgroundCoreActive: false,
              controlRecoverySucceeded: false,
              nativeSnapshot: authoritativeSessionSnapshot,
              explicitFailure: false,
            ),
            error: e,
          );
        } else if (!_isTransientGrpcFailure(e)) {
          grpcStopError = e;
          loggy.warning("background core stop failed before native terminal confirmation", e);
        }
      } catch (e) {
        loggy.error("failed to stop bg core: $e");
      }
      var nativeStopped = platformStopped || _platformConfirmsStopped(operationGeneration);
      try {
        if (!nativeStopped) {
          nativeStopped = await core
              .stop(generation: operationGeneration)
              .timeout(const Duration(seconds: 14), onTimeout: () => false);
        }
      } catch (error, stackTrace) {
        nativeStopped = false;
        if (errMsg.isEmpty) {
          errMsg = "native VPN service stop failed (${error.runtimeType})";
        }
        loggy.error("native VPN service stop failed", error, stackTrace);
      } finally {
        await _deleteCoreCurrentConfigSnapshot();
      }
      if (_isStaleOperation(operationGeneration, "stop_native_result")) return right(unit);
      if (!nativeStopped && grpcStopError != null && errMsg.isEmpty) {
        errMsg = grpcStopError.message ?? "failed to stop background core";
      }
      if (!nativeStopped) {
        loggy.warning("native core stop timed out; forcing local stopped state");
        if (errMsg.isEmpty) {
          errMsg = "native VPN service did not confirm stop";
        }
      }

      _transitionLifecycle(_CoreLifecycleState.stopped, reason: "stop complete");
      _clearRuntimeOutboundSnapshot("stop complete");
      if (currentState is! CoreStopped) {
        statusController.add(currentState = const CoreStatus.stopped());
      }
      if (errMsg.isNotEmpty) return left(errMsg);
      return right(unit);
    });
  }

  TaskEither<String, Unit> restart(
    String path,
    String name,
    bool disableMemoryLimit, {
    required int generation,
    String source = "restart",
  }) {
    if (_lifecycleState == _CoreLifecycleState.starting || _lifecycleState == _CoreLifecycleState.stopping) {
      loggy.info("restart requested during ${_lifecycleState.name}; queued");
    }
    return TaskEither(() {
      return _enqueueLifecycle("restart", () async {
        if (_isStaleOperation(generation, "restart_queue_entry")) return right(unit);
        try {
          await core.setSessionGeneration(generation);
        } catch (e) {
          if (_isStaleOperation(generation, "restart_set_generation", error: e)) return right(unit);
          rethrow;
        }
        if (_useMockCore) {
          _transitionLifecycle(_CoreLifecycleState.stopping, reason: "mock restart");
          statusController.add(currentState = const CoreStatus.stopping());
          await Future<void>.delayed(const Duration(milliseconds: 80));
          _transitionLifecycle(_CoreLifecycleState.starting, reason: "mock restart");
          statusController.add(currentState = const CoreStatus.starting());
          await Future<void>.delayed(const Duration(milliseconds: 140));
          if (_isStaleOperation(generation, "mock_restart")) return right(unit);
          _connectedGeneration = generation;
          _transitionLifecycle(_CoreLifecycleState.started, reason: "mock restart complete");
          statusController.add(currentState = const CoreStatus.started());
          return right(unit);
        }

        loggy.debug("restarting");
        _transitionLifecycle(_CoreLifecycleState.stopping, reason: "restart requested");
        statusController.add(currentState = const CoreStatus.stopping());

        var transportStage = TransportCloseStage.teardown;
        try {
          final oldClosed = await _withinExpectedTransportTeardown(TransportCloseIntent.restartReplacement, () async {
            await _closeSessionListeners(generation);
            try {
              await core.bgClient.stop(Empty(), options: CallOptions(timeout: const Duration(seconds: 3)));
            } on GrpcError catch (error) {
              if (!_isTransientGrpcTransportClose(error)) rethrow;
              _recordTransportCloseOutcome(
                source: "core_restart_old_generation",
                generation: generation,
                disposition: classifyTransportClose(
                  intent: TransportCloseIntent.restartReplacement,
                  stage: TransportCloseStage.teardown,
                  operationGeneration: generation,
                  operationCurrent: _sessionGeneration.isCurrent(
                    generation,
                    source: "core_restart_teardown_transport_close",
                  ),
                  backgroundCoreActive: false,
                  controlRecoverySucceeded: false,
                  nativeSnapshot: authoritativeSessionSnapshot,
                  explicitFailure: false,
                ),
                error: error,
              );
            }
            return core
                .stopForReplacement(generation: generation)
                .timeout(const Duration(seconds: 14), onTimeout: () => false);
          });
          if (_isStaleOperation(generation, "mode_switch_old_close")) return right(unit);
          if (!oldClosed) {
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "old generation close timeout");
            statusController.add(currentState = const CoreStatus.stopped());
            return left("old VPN generation did not close before restart");
          }
          if (source == "mode_switch") {
            loggy.warning(
              vpnDiagnosticEvent(
                "mode_switch_old_generation_closed",
                generation,
                details:
                    "operation_generation=$generation current_generation=${_sessionGeneration.current} "
                    "session_state=stopped source=config_option reason=teardown_completed",
              ),
            );
          }

          transportStage = TransportCloseStage.start;
          _transitionLifecycle(_CoreLifecycleState.starting, reason: "restart old generation closed");
          statusController.add(currentState = const CoreStatus.starting());
          final backgroundSetup = await core.setupBackground(path, name, generation: generation);
          if (_isStaleOperation(generation, "mode_switch_background_setup")) return right(unit);
          if (!backgroundSetup.isReady) {
            final nativeSnapshot = backgroundSetup.nativeSnapshot ?? authoritativeSessionSnapshot;
            final disposition = _classifyStartupFailure(
              generation: generation,
              signal: StartupFailureSignal.backgroundSetup,
              backgroundSetupFailure: backgroundSetup.failure,
              nativeSnapshot: nativeSnapshot,
            );
            _recordStartupOutcome(
              generation: generation,
              signal: StartupFailureSignal.backgroundSetup,
              disposition: disposition,
              backgroundSetupFailure: backgroundSetup.failure,
              nativeSnapshot: nativeSnapshot,
            );
            if (_completeNonIncidentStartupOutcome(generation, disposition, "restart background setup recovered")) {
              return right(unit);
            }
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "restart background setup failed");
            statusController.add(currentState = const CoreStatus.stopped());
            return left(
              "startup ${disposition.name}: background setup ${backgroundSetup.failure.name} "
              "generation=$generation native_phase=${nativeSnapshot?.phase.name ?? "none"}",
            );
          }

          await startListeningLogs("bg", core.bgClient);
          await startListeningStatus("bg", core.bgClient, generation: generation);
          final optionsResult = await _applyLatestCoreOptionsToBackground("restart");
          if (optionsResult.isLeft()) {
            final error = optionsResult.getLeft().toNullable() ?? "failed to apply core options";
            await core.stop(generation: generation);
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "restart options failed");
            statusController.add(currentState = const CoreStatus.stopped());
            return left("failed to apply core options: $error");
          }

          loggy.info(vpnDiagnosticEvent("core_start_requested", generation, details: "owner=flutter source=$source"));
          final res = await core.bgClient.start(
            StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit),
          );
          if (_isStaleOperation(generation, "core_restart_start_result")) return right(unit);
          if (res.messageType == MessageType.ALREADY_STARTED) {
            loggy.warning(vpnDiagnosticEvent("core_already_started_conflict", generation));
            await core.stop(generation: generation);
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "duplicate native core on restart");
            statusController.add(currentState = const CoreStatus.stopped());
            return left("core is already started by another session");
          }
          if (res.messageType != MessageType.EMPTY) {
            final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_restart_response");
            final disposition = _classifyStartupFailure(
              generation: generation,
              signal: StartupFailureSignal.coreResponse,
              nativeSnapshot: nativeSnapshot,
            );
            _recordStartupOutcome(
              generation: generation,
              signal: StartupFailureSignal.coreResponse,
              disposition: disposition,
              nativeSnapshot: nativeSnapshot,
            );
            if (_completeNonIncidentStartupOutcome(generation, disposition, "restart core response recovered")) {
              return right(unit);
            }
            await core.stop(generation: generation);
            _transitionLifecycle(_CoreLifecycleState.stopped, reason: "restart start failed");
            statusController.add(currentState = const CoreStatus.stopped());
            return left(
              "startup ${disposition.name}: core response ${res.messageType.name} "
              "generation=$generation native_phase=${nativeSnapshot?.phase.name ?? "none"}",
            );
          }
          await core.markCoreStarted(generation);
          if (_isStaleOperation(generation, "core_restart_mark_result")) return right(unit);
          _connectedGeneration = generation;
          await _emitRedactedEffectiveConfig(generation, "restart");
          if (source == "mode_switch") {
            loggy.warning(
              vpnDiagnosticEvent(
                "mode_switch_new_generation_started",
                generation,
                details:
                    "operation_generation=$generation current_generation=${_sessionGeneration.current} "
                    "session_state=starting source=config_option reason=start_gate_confirmed",
              ),
            );
          }
        } on GrpcError catch (e, st) {
          if (_isStaleOperation(generation, "core_restart_grpc", error: e)) return right(unit);
          if (isTunInterfacePermissionDenied(e)) {
            _recordTransportCloseOutcome(
              source: "core_restart",
              generation: generation,
              disposition: TransportCloseDisposition.realFailure,
              error: e,
              stackTrace: st,
              reportIncident: false,
            );
            await _cleanupFailedStartup(generation, "tun permission denied on restart");
            return left(e.message ?? e.toString());
          }
          final transientTransportClose = _isTransientGrpcTransportClose(e);
          if (!transientTransportClose || transportStage == TransportCloseStage.teardown) {
            _recordTransportCloseOutcome(
              source: "core_restart",
              generation: generation,
              disposition: TransportCloseDisposition.realFailure,
              error: e,
              stackTrace: st,
              reportIncident: false,
            );
            await _cleanupFailedStartup(generation, "grpc restart failure");
            return left("${e.message}");
          }
          final operationCurrent = _sessionGeneration.isCurrent(generation, source: "core_restart_transport_close");
          final backgroundCoreActive = operationCurrent && await _isBackgroundCoreReachable(attempts: 3);
          if (!backgroundCoreActive) {
            final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_restart_grpc_failure");
            final startupDisposition = _classifyStartupFailure(
              generation: generation,
              signal: StartupFailureSignal.grpcTransport,
              nativeSnapshot: nativeSnapshot,
            );
            _recordStartupOutcome(
              generation: generation,
              signal: StartupFailureSignal.grpcTransport,
              disposition: startupDisposition,
              nativeSnapshot: nativeSnapshot,
            );
            if (_completeNonIncidentStartupOutcome(
              generation,
              startupDisposition,
              "native restart recovered after grpc failure",
            )) {
              return right(unit);
            }
            _recordTransportCloseOutcome(
              source: "core_restart",
              generation: generation,
              disposition: classifyTransportClose(
                intent: TransportCloseIntent.none,
                stage: TransportCloseStage.start,
                operationGeneration: generation,
                operationCurrent: operationCurrent,
                backgroundCoreActive: false,
                controlRecoverySucceeded: false,
                nativeSnapshot: nativeSnapshot,
                explicitFailure: operationCurrent,
              ),
              error: e,
              stackTrace: st,
              reportIncident: false,
            );
            await _cleanupFailedStartup(generation, "restart endpoint not ready");
            return left(
              "startup ${startupDisposition.name}: grpc transport generation=$generation "
              "native_phase=${nativeSnapshot?.phase.name ?? "none"}",
            );
          }
          try {
            await core.markCoreStarted(generation);
          } catch (markError, markStackTrace) {
            final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_restart_mark_failed");
            final startupDisposition = _classifyStartupFailure(
              generation: generation,
              signal: StartupFailureSignal.nativeGate,
              nativeSnapshot: nativeSnapshot,
            );
            _recordStartupOutcome(
              generation: generation,
              signal: StartupFailureSignal.nativeGate,
              disposition: startupDisposition,
              nativeSnapshot: nativeSnapshot,
            );
            if (_completeNonIncidentStartupOutcome(
              generation,
              startupDisposition,
              "restart native start confirmation recovered",
            )) {
              return right(unit);
            }
            _recordTransportCloseOutcome(
              source: "core_restart_mark_failed",
              generation: generation,
              disposition: TransportCloseDisposition.realFailure,
              error: e,
              stackTrace: st,
              reportIncident: false,
            );
            loggy.warning(
              "native recovery confirmation failed after restart transport close",
              markError,
              markStackTrace,
            );
            await _cleanupFailedStartup(generation, "restart native start confirmation failed");
            return left(
              "startup ${startupDisposition.name}: native gate generation=$generation "
              "native_phase=${nativeSnapshot?.phase.name ?? "none"}",
            );
          }
          if (_isStaleOperation(generation, "core_restart_transport_mark")) return right(unit);
          _recordTransportCloseOutcome(
            source: "core_restart",
            generation: generation,
            disposition: classifyTransportClose(
              intent: TransportCloseIntent.none,
              stage: TransportCloseStage.start,
              operationGeneration: generation,
              operationCurrent: true,
              backgroundCoreActive: true,
              controlRecoverySucceeded: true,
              nativeSnapshot: authoritativeSessionSnapshot,
              explicitFailure: false,
            ),
            error: e,
          );
          _connectedGeneration = generation;
        } catch (e, st) {
          if (_isStaleOperation(generation, "core_restart_exception", error: e)) return right(unit);
          final nativeSnapshot = await _refreshStartupSnapshot(generation, "core_restart_exception");
          final disposition = _classifyStartupFailure(
            generation: generation,
            signal: StartupFailureSignal.unknown,
            nativeSnapshot: nativeSnapshot,
          );
          _recordStartupOutcome(
            generation: generation,
            signal: StartupFailureSignal.unknown,
            disposition: disposition,
            nativeSnapshot: nativeSnapshot,
          );
          if (_completeNonIncidentStartupOutcome(generation, disposition, "restart exception recovered")) {
            return right(unit);
          }
          loggy.warning("failed to restart bg core", e, st);
          await _cleanupFailedStartup(generation, "restart exception");
          return left(
            "startup ${disposition.name}: unknown restart failure generation=$generation "
            "native_phase=${nativeSnapshot?.phase.name ?? "none"}",
          );
        } finally {
          if (_sessionGeneration.isCurrent(generation, source: "core_restart_cleanup")) {
            await _deleteCoreCurrentConfigSnapshot();
          }
        }

        if (_isStaleOperation(generation, "restart_terminal_publication")) return right(unit);
        _transitionLifecycle(_CoreLifecycleState.started, reason: "restart complete");
        statusController.add(currentState = const CoreStatus.started());
        if (source == "mode_switch") {
          loggy.warning(
            vpnDiagnosticEvent(
              "mode_switch_completed",
              generation,
              details:
                  "operation_generation=$generation current_generation=${_sessionGeneration.current} "
                  "session_state=${_lifecycleState.name} source=config_option reason=single_generation_ready",
            ),
          );
        }
        ref.read(coreRestartSignalProvider.notifier).restart();
        return right(unit);
      });
    });
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

  Future<void> _emitRedactedEffectiveConfig(int generation, String phase) async {
    if (!_globalDataPlaneValidationEnabled || !PlatformUtils.isAndroid) return;
    try {
      final directories = ref.read(appDirectoriesProvider).requireValue;
      final file = File(p.join(directories.workingDir.path, "data", "current-config.json"));
      if (!await file.exists()) {
        loggy.warning("Stage 2.9 effective config snapshot is absent");
        return;
      }
      final redacted = GlobalDataPlaneConfigRedactor().redactJson(await file.readAsString());
      final encoded = base64Url.encode(utf8.encode(redacted));
      // Android's log payload is capped near 4 KiB. Keep the complete JSON
      // envelope below that limit after UTF-8 encoding.
      const chunkSize = 3000;
      final total = (encoded.length / chunkSize).ceil();
      for (var index = 0; index < total; index++) {
        final start = index * chunkSize;
        final end = min(encoded.length, start + chunkSize);
        final event = jsonEncode({
          "kind": "effective_config_chunk",
          "generation": generation.toString(),
          "phase": phase,
          "chunk": index + 1,
          "chunks": total,
          "encoding": "base64url-utf8",
          "data": encoded.substring(start, end),
        });
        await _platformChannel.invokeMethod<bool>("emit_route_evidence", "ZEON_ROUTE_VALIDATION $event");
      }
    } catch (error, stackTrace) {
      loggy.warning("Stage 2.9 effective config redaction failed", error, stackTrace);
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
      final generation = _sessionGeneration.current;
      if (!_sessionGeneration.isCurrent(generation, source: "select_outbound_request")) {
        return left("stale VPN session");
      }
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
        if (!_sessionGeneration.isCurrent(generation, source: "select_outbound_result")) {
          return left("stale VPN session");
        }
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
      final generation = _sessionGeneration.current;
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
        if (!_sessionGeneration.isCurrent(generation, source: "url_test_result")) {
          return left("stale VPN session");
        }
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
    yield* statusController.stream.map(
      (next) => _gateTerminalStatus(next, _sessionGeneration.current, "status_stream"),
    );
    // .endWith(const CoreStatus.stopped());
  }

  Future<void> startListeningStatus(String key, CoreClient cc, {int? generation}) async {
    final listenerGeneration = generation ?? _sessionGeneration.current;
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
          .asyncMap((event) => _applyCoreStatusFromListener(key, CoreStatus.fromCoreInfo(event), listenerGeneration)),
      onDone: () {
        loggy.warning(
          vpnDiagnosticEvent("grpc_disconnect", listenerGeneration, details: "source=${key}_status outcome=done"),
        );
        loggy.warning("status listener closed [$key], scheduling reconnect");
        _recoverStatusAfterListenerClose(key, null);
        if (_sessionGeneration.isCurrent(listenerGeneration, source: "status_listener_done[$key]")) {
          unawaited(
            _scheduleListenerReconnect(listenKey, () => startListeningStatus(key, cc, generation: listenerGeneration)),
          );
        }
      },
      onError: (error) {
        final Object listenerError = error is Object ? error : StateError("status listener failed without an error");
        loggy.warning(
          vpnDiagnosticEvent("grpc_disconnect", listenerGeneration, details: "source=${key}_status outcome=error"),
        );
        final teardownIntent = _activeTransportTeardownIntent;
        _recoverStatusAfterListenerClose(key, listenerError);
        unawaited(
          _handleListenerTransportClose(
            key: listenKey,
            generation: listenerGeneration,
            error: listenerError,
            teardownIntent: teardownIntent,
            reconnect: () => startListeningStatus(key, cc, generation: listenerGeneration),
          ),
        );
      },
    );
  }

  Future<void> startListeningLogs(String key, CoreClient cc) async {
    final listenerGeneration = _sessionGeneration.current;
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
          final logLevel = _coreLogLevelForAppLog(safeEvent);
          safeEvent.message.split('\n').forEach((line) {
            if (_routeEvidenceLogcatEnabled && Platform.isAndroid) {
              unawaited(_emitRouteEvidence(line));
            }
            loggy.log(logLevel, line);
            if (line.contains("[SelectorSwitch]")) {
              final details = selectorDiagnosticDetails(line);
              loggy.info(vpnDiagnosticEvent("selector_switch", listenerGeneration, details: details));
              if (details.contains("interrupt_external=true")) {
                loggy.warning(vpnDiagnosticEvent("selector_interrupt", listenerGeneration, details: details));
              }
            } else if (line.contains("[SelectorStaleResult]")) {
              loggy.warning(
                vpnDiagnosticEvent("stale_callback_ignored", listenerGeneration, details: "source=core_selector"),
              );
            }
          });
          return safeEvent;
        });
      },
      onDone: () {
        loggy.warning(
          vpnDiagnosticEvent("grpc_disconnect", listenerGeneration, details: "source=${key}_log outcome=done"),
        );
        loggy.warning("log listener closed [$key], scheduling reconnect");
        unawaited(_scheduleListenerReconnect(listenKey, () => startListeningLogs(key, cc)));
      },
      onError: (error) {
        final Object listenerError = error is Object ? error : StateError("log listener failed without an error");
        loggy.warning(
          vpnDiagnosticEvent("grpc_disconnect", listenerGeneration, details: "source=${key}_log outcome=error"),
        );
        final teardownIntent = _activeTransportTeardownIntent;
        unawaited(
          _handleListenerTransportClose(
            key: listenKey,
            generation: listenerGeneration,
            error: listenerError,
            teardownIntent: teardownIntent,
            reconnect: () => startListeningLogs(key, cc),
          ),
        );
      },
    );
  }

  loggyl.LogLevel _coreLogLevelForAppLog(LogMessage message) {
    final level = getLogLevel(message.level);
    if (level == loggyl.LogLevel.error && _isBenignCanceledSystemInfoLog(message.message)) {
      return loggyl.LogLevel.warning;
    }
    return level;
  }

  Future<void> _emitRouteEvidence(String line) async {
    try {
      await _platformChannel.invokeMethod<void>('emit_route_evidence', line);
    } on PlatformException {
      // Validation evidence must never affect the VPN or application lifecycle.
    } on MissingPluginException {
      // Non-Android and unit-test environments intentionally have no bridge.
    }
  }

  bool _isBenignCanceledSystemInfoLog(String message) {
    if (!PlatformUtils.isIOS) return false;
    final lower = message.toLowerCase();
    return lower.contains("send system info failed") &&
        lower.contains("code = canceled") &&
        lower.contains("context canceled");
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
      await _cancelSubscriptionBounded(sub, k);

      subscriptions.remove(k);
      _listenerReconnectAttempt.remove(k);
    }
  }

  Future<void> _closeSessionListeners(int generation) async {
    loggy.debug(vpnDiagnosticEvent("session_close_requested", generation, details: "owner=flutter_listeners"));
    final keys = subscriptions.keys.toList(growable: false);
    for (final key in keys) {
      final subscription = subscriptions.remove(key);
      await _cancelSubscriptionBounded(subscription, key);
    }
    _listenerReconnectAttempt.clear();
    _statusListenerRecoveryByKey.clear();
    _stoppingStatusWatchdogGeneration++;
    loggy.debug(vpnDiagnosticEvent("session_close_completed", generation, details: "owner=flutter_listeners"));
  }

  Future<void> _cancelSubscriptionBounded(StreamSubscription<dynamic>? subscription, String key) async {
    if (subscription == null) return;
    try {
      await subscription.cancel().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      loggy.warning("listener cancellation timed out [$key]; lifecycle cleanup will continue");
    } catch (error, stackTrace) {
      loggy.warning("listener cancellation failed [$key]; lifecycle cleanup will continue", error, stackTrace);
    }
  }

  Future<void> _logRuntimeIndicators(int generation, String source) async {
    try {
      final info = await core.bgClient.getSystemInfo(Empty()).timeout(const Duration(milliseconds: 800));
      loggy.info(
        vpnDiagnosticEvent(
          "runtime_indicators",
          generation,
          details:
              "source=$source memory_bytes=${info.memory} goroutines=${info.goroutines} "
              "connections_out=${info.connectionsOut}",
        ),
      );
    } catch (_) {
      // Runtime indicators are diagnostic-only and must never block lifecycle.
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
        if (onError == null) {
          loggy.log(loggyl.LogLevel.error, 'Stream error: $error');
        }
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

  String _currentRuntimeEpoch() {
    final epoch = authoritativeSessionSnapshot?.runtimeEpoch;
    return epoch == null || epoch.isEmpty ? "none" : epoch;
  }

  Map<String, StreamSubscription?> _captureCloseFrontListeners() => Map<String, StreamSubscription?>.fromEntries(
    subscriptions.entries.where(
      (entry) => entry.value != null && (entry.key.startsWith("fg") || entry.key.startsWith("bg")),
    ),
  );

  Future<void> _closeCapturedFrontResources(
    CoreClient capturedForegroundClient,
    Map<String, StreamSubscription?> capturedListeners,
  ) async {
    for (final entry in capturedListeners.entries) {
      final currentSubscription = subscriptions[entry.key];
      if (identical(currentSubscription, entry.value)) {
        subscriptions.remove(entry.key);
        _listenerReconnectAttempt.remove(entry.key);
      }
      await _cancelSubscriptionBounded(entry.value, entry.key);
    }
    try {
      await capturedForegroundClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL_INSECURE));
    } catch (_) {
      // Best-effort close; the alternate mode below may still succeed.
    }
    try {
      await capturedForegroundClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL));
    } catch (_) {
      // Best-effort close during shutdown.
    }
  }

  Future<void> closeFront() async {
    final operationSequence = ++_closeFrontOperationSequence;
    final capturedGeneration = _sessionGeneration.current;
    final capturedRuntimeEpoch = _currentRuntimeEpoch();
    final capturedResumeSequence = _appResumeSequence;
    final capturedLifecycleEpoch = _foregroundLifecycleEpoch;
    final initialized = core.isInitialized();
    final singleChannel = initialized && core.isSingleChannel();
    final capturedForegroundClient = initialized && !singleChannel ? core.fgClient : null;
    final capturedListeners = initialized && !singleChannel
        ? _captureCloseFrontListeners()
        : const <String, StreamSubscription?>{};
    if (!initialized) return;

    var bgStillActive = false;
    PortProbeObservation? rawProbe;
    if (!singleChannel) {
      try {
        bgStillActive = await core.isActiveBg(onPortProbe: (observation) => rawProbe = observation);
      } catch (_) {
        // A failed liveness probe is inconclusive and cannot prove a stop.
      }
    }
    final backgroundState = closeFrontBackgroundState(
      singleChannel: singleChannel,
      backgroundActive: bgStillActive,
      observation: rawProbe,
    );

    if (capturedForegroundClient != null) {
      await _withinExpectedTransportTeardown(TransportCloseIntent.foregroundClose, () async {
        await _closeCapturedFrontResources(capturedForegroundClient, capturedListeners);
      });
    }

    final prePublishNativeSnapshot = authoritativeSessionSnapshot;
    final nativeGenerationAdvanced =
        prePublishNativeSnapshot != null && prePublishNativeSnapshot.generation > capturedGeneration;
    final nativeProvesConnected =
        prePublishNativeSnapshot != null &&
        prePublishNativeSnapshot.generation == capturedGeneration &&
        prePublishNativeSnapshot.provesConnected;
    final nativeLifecycleIntentReserved =
        prePublishNativeSnapshot != null &&
        prePublishNativeSnapshot.generation == capturedGeneration &&
        switch (prePublishNativeSnapshot.phase) {
          VpnSessionPhase.startRequested ||
          VpnSessionPhase.startingPlatform ||
          VpnSessionPhase.startingCore ||
          VpnSessionPhase.waitingTun ||
          VpnSessionPhase.verifying ||
          VpnSessionPhase.stopRequested ||
          VpnSessionPhase.stopping => true,
          _ => false,
        };
    final operationCurrent =
        capturedGeneration == _sessionGeneration.current &&
        capturedRuntimeEpoch == _currentRuntimeEpoch() &&
        capturedResumeSequence == _appResumeSequence &&
        capturedLifecycleEpoch == _foregroundLifecycleEpoch &&
        operationSequence == _closeFrontOperationSequence &&
        !nativeGenerationAdvanced;
    final lifecycleIntentReserved =
        _lifecycleState == _CoreLifecycleState.starting ||
        _lifecycleState == _CoreLifecycleState.stopping ||
        nativeLifecycleIntentReserved;
    final decision = classifyCloseFrontPublication(
      operationCurrent: operationCurrent,
      backgroundState: backgroundState,
      nativeProvesConnected: nativeProvesConnected,
      lifecycleIntentReserved: lifecycleIntentReserved,
      currentStatus: currentState,
    );
    switch (decision) {
      case CloseFrontPublicationDecision.publishStarted:
        _transitionLifecycle(_CoreLifecycleState.started, reason: "close front while bg active");
        statusController.add(currentState = const CoreStatus.started());
      case CloseFrontPublicationDecision.nativeConnectedOverride:
        if (currentState is! CoreStarted) {
          _transitionLifecycle(_CoreLifecycleState.started, reason: "close front native connected override");
          statusController.add(currentState = const CoreStatus.started());
        }
      case CloseFrontPublicationDecision.publishStopped:
        _transitionLifecycle(_CoreLifecycleState.stopped, reason: "close front confirmed inactive");
        statusController.add(currentState = const CoreStatus.stopped());
      case CloseFrontPublicationDecision.preserveStarted ||
          CloseFrontPublicationDecision.preserveStopped ||
          CloseFrontPublicationDecision.preserveUnknown ||
          CloseFrontPublicationDecision.preserveLifecycleIntent ||
          CloseFrontPublicationDecision.skipStaleOperation:
        break;
    }
  }
}
