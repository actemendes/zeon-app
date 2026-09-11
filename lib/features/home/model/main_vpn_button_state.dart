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
        recoverable: false,
        failureCode: '',
        action: MainVpnButtonAction.none,
        visualState: MainVpnButtonVisualState.loading,
        enabled: false,
      );

  factory MainVpnButtonState.fromSnapshot(VpnSessionSnapshot snapshot) {
    final action = switch (snapshot.phase) {
      VpnSessionPhase.idle || VpnSessionPhase.disconnected => MainVpnButtonAction.start,
      VpnSessionPhase.failed when snapshot.recoverable => MainVpnButtonAction.start,
      VpnSessionPhase.permissionRequired ||
      VpnSessionPhase.startRequested ||
      VpnSessionPhase.startingPlatform ||
      VpnSessionPhase.startingCore ||
      VpnSessionPhase.waitingTun ||
      VpnSessionPhase.verifying ||
      VpnSessionPhase.connected => MainVpnButtonAction.stop,
      VpnSessionPhase.stopRequested || VpnSessionPhase.stopping || VpnSessionPhase.failed => MainVpnButtonAction.none,
    };
    final visualState = switch (snapshot.phase) {
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
      recoverable: snapshot.recoverable,
      failureCode: snapshot.failureCode,
      action: action,
      visualState: visualState,
      enabled: action != MainVpnButtonAction.none,
    );
  }

  /// Non-Android compatibility path. Android must always use [fromSnapshot].
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
  final bool recoverable;
  final String failureCode;
  final MainVpnButtonAction action;
  final MainVpnButtonVisualState visualState;
  final bool enabled;

  bool get isConnected => phase == VpnSessionPhase.connected;

  bool get isStarting => switch (phase) {
    VpnSessionPhase.permissionRequired ||
    VpnSessionPhase.startRequested ||
    VpnSessionPhase.startingPlatform ||
    VpnSessionPhase.startingCore ||
    VpnSessionPhase.waitingTun ||
    VpnSessionPhase.verifying => true,
    _ => false,
  };

  bool get isStopping => switch (phase) {
    VpnSessionPhase.stopRequested || VpnSessionPhase.stopping => true,
    _ => false,
  };

  bool get blocksStart => switch (phase) {
    VpnSessionPhase.permissionRequired ||
    VpnSessionPhase.startRequested ||
    VpnSessionPhase.startingPlatform ||
    VpnSessionPhase.startingCore ||
    VpnSessionPhase.waitingTun ||
    VpnSessionPhase.verifying ||
    VpnSessionPhase.connected ||
    VpnSessionPhase.stopRequested ||
    VpnSessionPhase.stopping => true,
    _ => false,
  };

  bool represents(VpnSessionSnapshot snapshot) =>
      runtimeEpoch == snapshot.runtimeEpoch &&
      generation == snapshot.generation &&
      phase == snapshot.phase &&
      requestedAction == snapshot.requestedAction &&
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
