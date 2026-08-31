import 'package:meta/meta.dart';
import 'package:zeon/singbox/model/core_status.dart';

enum VpnSessionPhase {
  idle,
  permissionRequired,
  startRequested,
  startingPlatform,
  startingCore,
  waitingTun,
  verifying,
  connected,
  stopRequested,
  stopping,
  disconnected,
  failed;

  static VpnSessionPhase parse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase().replaceAll('-', '_') ?? '';
    return switch (normalized) {
      'permission_required' => permissionRequired,
      'start_requested' => startRequested,
      'starting_platform' => startingPlatform,
      'starting_core' => startingCore,
      'waiting_tun' => waitingTun,
      'verifying' => verifying,
      'connected' => connected,
      'stop_requested' => stopRequested,
      'stopping' => stopping,
      'disconnected' => disconnected,
      'failed' => failed,
      _ => idle,
    };
  }
}

enum VpnStopSource {
  none,
  flutter,
  system,
  notification,
  tile,
  shortcut,
  revoke,
  destroy,
  replacement,
  internal,
  unknown;

  static VpnStopSource parse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return switch (normalized) {
      '' => none,
      'flutter' => flutter,
      'system' => system,
      'notification' => notification,
      'tile' => tile,
      'shortcut' => shortcut,
      'revoke' => revoke,
      'destroy' => destroy,
      'replacement' => replacement,
      'internal' => internal,
      _ => unknown,
    };
  }

  bool get isExternalIntentional => switch (this) {
    system || notification || tile || shortcut || revoke => true,
    _ => false,
  };
}

@immutable
class VpnSessionSnapshot {
  const VpnSessionSnapshot({
    required this.generation,
    required this.runtimeEpoch,
    required this.sequenceNumber,
    required this.snapshotVersion,
    required this.phase,
    this.requestedAction = '',
    this.stopSource = VpnStopSource.none,
    this.coreReady = false,
    this.coreStarted = false,
    this.commandEndpointReady = false,
    this.tunnelReady = false,
    this.protectSucceeded = false,
    this.platformVpnValidated = false,
    this.selectedOutboundId = '',
    this.selectedOutboundLabel = '',
    this.strategy = '',
    this.failureCode = '',
    this.failureOwner = '',
    this.recoverable = false,
  });

  factory VpnSessionSnapshot.fromEvent(Object? event) {
    final map = event is Map ? event : const <Object?, Object?>{};
    int integer(String key) => switch (map[key]) {
      final int value => value,
      final Object value => int.tryParse(value.toString()) ?? 0,
      _ => 0,
    };
    bool boolean(String key) => switch (map[key]) {
      final bool value => value,
      final Object value => value.toString().toLowerCase() == 'true',
      _ => false,
    };
    String text(String key) => map[key]?.toString() ?? '';

    return VpnSessionSnapshot(
      generation: integer('generation'),
      runtimeEpoch: text('runtimeEpoch'),
      sequenceNumber: integer('sequenceNumber'),
      snapshotVersion: integer('snapshotVersion'),
      phase: VpnSessionPhase.parse(map['phase']),
      requestedAction: text('requestedAction'),
      stopSource: VpnStopSource.parse(map['stopSource']),
      coreReady: boolean('coreReady'),
      coreStarted: boolean('coreStarted'),
      commandEndpointReady: boolean('commandEndpointReady'),
      tunnelReady: boolean('tunnelReady'),
      protectSucceeded: boolean('protectSucceeded'),
      platformVpnValidated: boolean('platformVpnValidated'),
      selectedOutboundId: text('selectedOutboundId'),
      selectedOutboundLabel: text('selectedOutboundLabel'),
      strategy: text('strategy'),
      failureCode: text('failureCode'),
      failureOwner: text('failureOwner'),
      recoverable: boolean('recoverable'),
    );
  }

  final int generation;
  final String runtimeEpoch;
  final int sequenceNumber;
  final int snapshotVersion;
  final VpnSessionPhase phase;
  final String requestedAction;
  final VpnStopSource stopSource;
  final bool coreReady;
  final bool coreStarted;
  final bool commandEndpointReady;
  final bool tunnelReady;
  final bool protectSucceeded;
  final bool platformVpnValidated;
  final String selectedOutboundId;
  final String selectedOutboundLabel;
  final String strategy;
  final String failureCode;
  final String failureOwner;
  final bool recoverable;

  bool get isTerminalStop => phase == VpnSessionPhase.disconnected && requestedAction == 'stop';

  bool get isExternalIntentionalStop => isTerminalStop && stopSource.isExternalIntentional;

  /// A platform teardown that belongs to a still-active Connect operation.
  ///
  /// Android and iOS may have to release an older packet-tunnel owner before
  /// starting the new owner for the same generation. That transient
  /// DISCONNECTED snapshot is authoritative transport state, but it is not a
  /// terminal user intent and must not make the main button look idle.
  bool get isReplacementTransition =>
      stopSource == VpnStopSource.replacement &&
      (phase == VpnSessionPhase.stopRequested ||
          phase == VpnSessionPhase.stopping ||
          phase == VpnSessionPhase.disconnected);

  /// The native owner has accepted Connect but the packet tunnel is still
  /// inactive (for example while preferences or permission are prepared).
  bool get isPendingConnectWhileInactive =>
      generation > 0 &&
      requestedAction == 'connect' &&
      (phase == VpnSessionPhase.idle || phase == VpnSessionPhase.disconnected);

  bool get provesConnected =>
      generation > 0 &&
      phase == VpnSessionPhase.connected &&
      coreReady &&
      coreStarted &&
      commandEndpointReady &&
      tunnelReady &&
      protectSucceeded &&
      selectedOutboundId.isNotEmpty;

  CoreStatus toCoreStatus() => switch (phase) {
    VpnSessionPhase.connected when provesConnected => const CoreStatus.started(),
    VpnSessionPhase.stopRequested || VpnSessionPhase.stopping => const CoreStatus.stopping(),
    VpnSessionPhase.idle || VpnSessionPhase.disconnected => const CoreStatus.stopped(),
    VpnSessionPhase.failed => CoreStatus.stopped(message: failureCode),
    _ => const CoreStatus.starting(),
  };
}

enum VpnSnapshotDisposition { accepted, duplicate, stale, gap }

class VpnSessionSnapshotGate {
  String _runtimeEpoch = '';
  int _generation = 0;
  int _sequence = 0;
  int _snapshotVersion = 0;
  VpnSessionSnapshot? _current;

  VpnSessionSnapshot? get current => _current;

  VpnSnapshotDisposition classify(VpnSessionSnapshot next) {
    if (next.runtimeEpoch.isEmpty || next.sequenceNumber <= 0 || next.snapshotVersion <= 0) {
      return VpnSnapshotDisposition.stale;
    }
    if (_runtimeEpoch.isNotEmpty && next.runtimeEpoch != _runtimeEpoch) {
      return VpnSnapshotDisposition.accepted;
    }
    if (next.generation < _generation || next.snapshotVersion < _snapshotVersion) {
      return VpnSnapshotDisposition.stale;
    }
    final sameGenerationConnectAfterPreparationStop =
        next.generation == _generation &&
        _current != null &&
        (_current!.phase == VpnSessionPhase.disconnected || _current!.phase == VpnSessionPhase.failed) &&
        _phaseRank(next.phase) >= _phaseRank(VpnSessionPhase.startRequested) &&
        _phaseRank(next.phase) <= _phaseRank(VpnSessionPhase.connected) &&
        next.requestedAction == 'connect';
    if (next.generation == _generation &&
        _current != null &&
        _phaseRank(next.phase) < _phaseRank(_current!.phase) &&
        !sameGenerationConnectAfterPreparationStop) {
      return VpnSnapshotDisposition.stale;
    }
    if (next.sequenceNumber == _sequence && next.snapshotVersion == _snapshotVersion) {
      return VpnSnapshotDisposition.duplicate;
    }
    if (_sequence > 0 && next.sequenceNumber > _sequence + 1) {
      return VpnSnapshotDisposition.gap;
    }
    if (next.sequenceNumber <= _sequence) {
      return VpnSnapshotDisposition.stale;
    }
    return VpnSnapshotDisposition.accepted;
  }

  int _phaseRank(VpnSessionPhase phase) => switch (phase) {
    VpnSessionPhase.idle => 0,
    VpnSessionPhase.permissionRequired => 1,
    VpnSessionPhase.startRequested => 2,
    VpnSessionPhase.startingPlatform => 3,
    VpnSessionPhase.startingCore => 4,
    VpnSessionPhase.waitingTun => 5,
    VpnSessionPhase.verifying => 6,
    VpnSessionPhase.connected => 7,
    VpnSessionPhase.stopRequested => 8,
    VpnSessionPhase.stopping => 9,
    VpnSessionPhase.disconnected || VpnSessionPhase.failed => 10,
  };

  void acceptAuthoritative(VpnSessionSnapshot next) {
    _runtimeEpoch = next.runtimeEpoch;
    _generation = next.generation;
    _sequence = next.sequenceNumber;
    _snapshotVersion = next.snapshotVersion;
    _current = next;
  }

  /// Accepts a MethodChannel/authoritative read only when it is not older
  /// than a snapshot already delivered by the EventChannel. Gaps are allowed
  /// because the read represents the platform's current complete state.
  bool acceptResynced(VpnSessionSnapshot next) {
    final disposition = classify(next);
    if (disposition == VpnSnapshotDisposition.stale || disposition == VpnSnapshotDisposition.duplicate) {
      return false;
    }
    acceptAuthoritative(next);
    return true;
  }

  bool accept(VpnSessionSnapshot next) {
    final disposition = classify(next);
    if (disposition != VpnSnapshotDisposition.accepted) return false;
    acceptAuthoritative(next);
    return true;
  }
}
