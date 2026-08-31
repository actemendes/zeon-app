import 'package:flutter/foundation.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

enum MainVpnButtonAction { start, stop, none }

enum MainVpnButtonVisualState { off, loading, connected, failed }

@immutable
class MainVpnButtonState {
  const MainVpnButtonState._({
    required this.phase,
    required this.generation,
    required this.runtimeEpoch,
    required this.requestedAction,
    required this.stopSource,
    required this.recoverable,
    required this.failureCode,
    required this.action,
    required this.visualState,
    required this.enabled,
  });

  const MainVpnButtonState.loading()
    : this._(
        phase: VpnSessionPhase.idle,
        generation: 0,
        runtimeEpoch: '',
        requestedAction: '',
        stopSource: VpnStopSource.none,
        recoverable: false,
        failureCode: '',
        action: MainVpnButtonAction.none,
        visualState: MainVpnButtonVisualState.loading,
        enabled: false,
      );

  factory MainVpnButtonState.fromSnapshot(VpnSessionSnapshot snapshot) {
    final connectTransition = snapshot.isReplacementTransition || snapshot.isPendingConnectWhileInactive;
    final action = connectTransition
        ? MainVpnButtonAction.stop
        : switch (snapshot.phase) {
            VpnSessionPhase.idle || VpnSessionPhase.disconnected => MainVpnButtonAction.start,
            VpnSessionPhase.failed when snapshot.recoverable => MainVpnButtonAction.start,
            VpnSessionPhase.permissionRequired ||
            VpnSessionPhase.startRequested ||
            VpnSessionPhase.startingPlatform ||
            VpnSessionPhase.startingCore ||
            VpnSessionPhase.waitingTun ||
            VpnSessionPhase.verifying ||
            VpnSessionPhase.connected => MainVpnButtonAction.stop,
            VpnSessionPhase.stopRequested ||
            VpnSessionPhase.stopping ||
            VpnSessionPhase.failed => MainVpnButtonAction.none,
          };
    final visualState = connectTransition
        ? MainVpnButtonVisualState.loading
        : switch (snapshot.phase) {
            VpnSessionPhase.connected => MainVpnButtonVisualState.connected,
            VpnSessionPhase.permissionRequired ||
            VpnSessionPhase.startRequested ||
            VpnSessionPhase.startingPlatform ||
            VpnSessionPhase.startingCore ||
            VpnSessionPhase.waitingTun ||
            VpnSessionPhase.verifying ||
            VpnSessionPhase.stopRequested ||
            VpnSessionPhase.stopping => MainVpnButtonVisualState.loading,
            VpnSessionPhase.failed => MainVpnButtonVisualState.failed,
            VpnSessionPhase.idle || VpnSessionPhase.disconnected => MainVpnButtonVisualState.off,
          };
    return MainVpnButtonState._(
      phase: snapshot.phase,
      generation: snapshot.generation,
      runtimeEpoch: snapshot.runtimeEpoch,
      requestedAction: snapshot.requestedAction,
      stopSource: snapshot.stopSource,
      recoverable: snapshot.recoverable,
      failureCode: snapshot.failureCode,
      action: action,
      visualState: visualState,
      enabled: action != MainVpnButtonAction.none,
    );
  }

  /// Reconciles the native authority with the local command that has already
  /// been accepted by the UI but may not have reached NetworkExtension yet.
  ///
  /// Native terminal failures and explicit system/user stops always win. A
  /// local transient only masks an inactive preparation/replacement snapshot
  /// or a stale pre-command snapshot.
  factory MainVpnButtonState.fromSources({
    required VpnSessionSnapshot? snapshot,
    required ConnectionStatus? localStatus,
    bool? localDesiredRunning,
    bool localStopRetry = false,
    bool localLoading = false,
    bool localHasError = false,
  }) {
    if (snapshot == null) {
      if (localHasError) return const MainVpnButtonState.recoverableFailure();
      if (localStatus == null && localLoading) return const MainVpnButtonState.loading();
      return MainVpnButtonState.fromLegacyConnectionStatus(localStatus);
    }

    final authoritative = MainVpnButtonState.fromSnapshot(snapshot);
    final externalStop = snapshot.requestedAction == 'stop' && snapshot.stopSource.isExternalIntentional;
    final newerLocalStart = localDesiredRunning == true && localStatus is Connecting;
    final failedStop =
        snapshot.phase == VpnSessionPhase.failed &&
        (snapshot.requestedAction == 'stop' || localStatus is Disconnecting || localStopRetry);
    if (failedStop) return MainVpnButtonState._retryableStop(snapshot);
    if (snapshot.phase == VpnSessionPhase.failed || (externalStop && !newerLocalStart)) {
      return authoritative;
    }
    if (localHasError) {
      // A Stop watchdog error may retain Disconnecting as AsyncError.value.
      // A native STOPPING snapshot is non-terminal even though it no longer
      // satisfies provesConnected. Keep the retry action as STOP; presenting
      // START here would replace/resurrect the tunnel the user just stopped.
      final retryingStop = (localStopRetry || localStatus is Disconnecting) && !snapshot.isTerminalStop;
      if (retryingStop) return MainVpnButtonState._retryableStop(snapshot);
      if (snapshot.provesConnected) return authoritative;
      return MainVpnButtonState._project(snapshot, VpnSessionPhase.failed, recoverable: true);
    }
    if (localStatus is Disconnecting) {
      return snapshot.isTerminalStop ? authoritative : MainVpnButtonState._project(snapshot, VpnSessionPhase.stopping);
    }
    if (snapshot.provesConnected) return authoritative;
    return switch (localStatus) {
      Connecting() => MainVpnButtonState._project(snapshot, VpnSessionPhase.startingCore),
      _ => authoritative,
    };
  }

  const MainVpnButtonState.recoverableFailure()
    : this._(
        phase: VpnSessionPhase.failed,
        generation: 0,
        runtimeEpoch: '',
        requestedAction: 'connect',
        stopSource: VpnStopSource.none,
        recoverable: true,
        failureCode: 'local_connection_failure',
        action: MainVpnButtonAction.start,
        visualState: MainVpnButtonVisualState.failed,
        enabled: true,
      );

  factory MainVpnButtonState._retryableStop(VpnSessionSnapshot snapshot) => MainVpnButtonState._(
    phase: VpnSessionPhase.stopping,
    generation: snapshot.generation,
    runtimeEpoch: snapshot.runtimeEpoch,
    requestedAction: 'stop',
    // This projection belongs to the local retry intent, even if the cached
    // native snapshot described a replacement teardown. Keeping replacement
    // here would make isStopping/labels disagree with the STOP action.
    stopSource: VpnStopSource.flutter,
    recoverable: true,
    failureCode: 'local_stop_timeout',
    action: MainVpnButtonAction.stop,
    visualState: MainVpnButtonVisualState.failed,
    enabled: true,
  );

  factory MainVpnButtonState._project(VpnSessionSnapshot snapshot, VpnSessionPhase phase, {bool recoverable = false}) {
    return MainVpnButtonState.fromSnapshot(
      VpnSessionSnapshot(
        generation: snapshot.generation,
        runtimeEpoch: snapshot.runtimeEpoch,
        sequenceNumber: snapshot.sequenceNumber,
        snapshotVersion: snapshot.snapshotVersion,
        phase: phase,
        requestedAction: phase == VpnSessionPhase.stopping ? 'stop' : 'connect',
        stopSource: phase == VpnSessionPhase.stopping ? VpnStopSource.flutter : VpnStopSource.none,
        coreReady: snapshot.coreReady,
        coreStarted: snapshot.coreStarted,
        commandEndpointReady: snapshot.commandEndpointReady,
        tunnelReady: snapshot.tunnelReady,
        protectSucceeded: snapshot.protectSucceeded,
        platformVpnValidated: snapshot.platformVpnValidated,
        selectedOutboundId: snapshot.selectedOutboundId,
        selectedOutboundLabel: snapshot.selectedOutboundLabel,
        strategy: snapshot.strategy,
        failureCode: phase == VpnSessionPhase.failed ? 'local_connection_failure' : snapshot.failureCode,
        failureOwner: snapshot.failureOwner,
        recoverable: recoverable,
      ),
    );
  }

  /// Compatibility path for platforms without authoritative VPN snapshots.
  factory MainVpnButtonState.fromLegacyConnectionStatus(ConnectionStatus? status) {
    final phase = switch (status) {
      Connected() => VpnSessionPhase.connected,
      Connecting() => VpnSessionPhase.startingCore,
      Disconnecting() => VpnSessionPhase.stopping,
      Disconnected() || null => VpnSessionPhase.disconnected,
    };
    return MainVpnButtonState.fromSnapshot(
      VpnSessionSnapshot(
        generation: 0,
        runtimeEpoch: 'non-android',
        sequenceNumber: 1,
        snapshotVersion: 1,
        phase: phase,
        requestedAction: switch (phase) {
          VpnSessionPhase.connected || VpnSessionPhase.stopping => 'stop',
          _ => 'connect',
        },
        recoverable: true,
      ),
    );
  }

  final VpnSessionPhase phase;
  final int generation;
  final String runtimeEpoch;
  final String requestedAction;
  final VpnStopSource stopSource;
  final bool recoverable;
  final String failureCode;
  final MainVpnButtonAction action;
  final MainVpnButtonVisualState visualState;
  final bool enabled;

  bool get isConnected => phase == VpnSessionPhase.connected;

  bool get isStarting =>
      (stopSource == VpnStopSource.replacement &&
          (phase == VpnSessionPhase.stopRequested ||
              phase == VpnSessionPhase.stopping ||
              phase == VpnSessionPhase.disconnected)) ||
      (requestedAction == 'connect' &&
          generation > 0 &&
          (phase == VpnSessionPhase.idle || phase == VpnSessionPhase.disconnected)) ||
      switch (phase) {
        VpnSessionPhase.permissionRequired ||
        VpnSessionPhase.startRequested ||
        VpnSessionPhase.startingPlatform ||
        VpnSessionPhase.startingCore ||
        VpnSessionPhase.waitingTun ||
        VpnSessionPhase.verifying => true,
        _ => false,
      };

  bool get isStopping =>
      stopSource != VpnStopSource.replacement &&
      switch (phase) {
        VpnSessionPhase.stopRequested || VpnSessionPhase.stopping => true,
        _ => false,
      };

  bool get blocksStart => isStarting || isStopping || phase == VpnSessionPhase.connected;

  bool represents(VpnSessionSnapshot snapshot) =>
      runtimeEpoch == snapshot.runtimeEpoch &&
      generation == snapshot.generation &&
      phase == snapshot.phase &&
      requestedAction == snapshot.requestedAction &&
      stopSource == snapshot.stopSource &&
      recoverable == snapshot.recoverable &&
      failureCode == snapshot.failureCode;

  MainVpnButtonPresentation present(TranslationsEn t) {
    final label = switch (phase) {
      _ when isStarting => t.connection.connecting,
      VpnSessionPhase.connected => t.connection.connected,
      _ when isStopping => t.connection.disconnecting,
      VpnSessionPhase.failed when !recoverable => t.errors.connection.connectionError,
      _ => t.connection.tapToConnect,
    };
    final semanticsLabel = switch (phase) {
      _ when isStarting => t.connection.connectingSemantics,
      VpnSessionPhase.connected => t.connection.tapToDisconnect,
      _ when isStopping => t.connection.disconnectingSemantics,
      VpnSessionPhase.failed when !recoverable => t.errors.connection.connectionError,
      _ => t.connection.tapToConnect,
    };
    return MainVpnButtonPresentation(state: this, label: label, semanticsLabel: semanticsLabel);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MainVpnButtonState &&
          phase == other.phase &&
          generation == other.generation &&
          runtimeEpoch == other.runtimeEpoch &&
          requestedAction == other.requestedAction &&
          stopSource == other.stopSource &&
          recoverable == other.recoverable &&
          failureCode == other.failureCode &&
          action == other.action &&
          visualState == other.visualState &&
          enabled == other.enabled;

  @override
  int get hashCode => Object.hash(
    phase,
    generation,
    runtimeEpoch,
    requestedAction,
    stopSource,
    recoverable,
    failureCode,
    action,
    visualState,
    enabled,
  );
}

@immutable
class MainVpnButtonPresentation {
  const MainVpnButtonPresentation({required this.state, required this.label, required this.semanticsLabel});

  final MainVpnButtonState state;
  final String label;
  final String semanticsLabel;
}
