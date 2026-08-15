import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/connection/data/connection_repository.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

VpnSessionSnapshot snapshot({
  int generation = 1,
  int sequence = 1,
  int version = 1,
  String epoch = 'process-a',
  VpnSessionPhase phase = VpnSessionPhase.startingCore,
  bool ready = false,
  String requestedAction = '',
  VpnStopSource stopSource = VpnStopSource.none,
}) => VpnSessionSnapshot(
  generation: generation,
  runtimeEpoch: epoch,
  sequenceNumber: sequence,
  snapshotVersion: version,
  phase: phase,
  requestedAction: requestedAction,
  stopSource: stopSource,
  coreReady: ready,
  coreStarted: ready,
  commandEndpointReady: ready,
  tunnelReady: ready,
  protectSucceeded: ready,
  platformVpnValidated: ready,
  selectedOutboundId: ready ? 'opaque-outbound' : '',
);

void main() {
  group('iOS system VPN preparation guard', () {
    test('fails closed for unknown state and allows preparation after an explicit stop', () {
      expect(
        shouldPrepareSystemVpnForSnapshot(null),
        isFalse,
        reason: 'unknown bootstrap state may belong to a live tunnel from the previous host process',
      );
      expect(shouldPrepareSystemVpnForSnapshot(snapshot(generation: 0, phase: VpnSessionPhase.disconnected)), isTrue);
      expect(
        shouldPrepareSystemVpnForSnapshot(
          snapshot(generation: 10, phase: VpnSessionPhase.disconnected, requestedAction: 'prepare'),
        ),
        isTrue,
      );
      expect(
        shouldPrepareSystemVpnForSnapshot(
          snapshot(generation: 10, phase: VpnSessionPhase.disconnected, requestedAction: 'stop'),
        ),
        isTrue,
      );
    });

    test('cannot supersede an active or already prepared connection generation', () {
      for (final phase in [VpnSessionPhase.startingPlatform, VpnSessionPhase.verifying, VpnSessionPhase.connected]) {
        expect(
          shouldPrepareSystemVpnForSnapshot(snapshot(generation: 11, phase: phase, requestedAction: 'connect')),
          isFalse,
        );
      }
      expect(
        shouldPrepareSystemVpnForSnapshot(
          snapshot(generation: 11, phase: VpnSessionPhase.disconnected, requestedAction: 'connect'),
        ),
        isFalse,
      );
      for (final phase in [VpnSessionPhase.startingPlatform, VpnSessionPhase.verifying, VpnSessionPhase.connected]) {
        expect(
          shouldPrepareSystemVpnForSnapshot(snapshot(generation: 0, phase: phase, requestedAction: 'connect')),
          isFalse,
          reason: 'cold-host adoption must win even before its provider generation is known',
        );
      }
    });
  });

  group('VpnSessionSnapshotGate', () {
    test('rejects stale and duplicate events', () {
      final gate = VpnSessionSnapshotGate();
      expect(gate.accept(snapshot()), isTrue);
      expect(gate.classify(snapshot()), VpnSnapshotDisposition.duplicate);
      expect(gate.classify(snapshot(generation: 0, sequence: 2, version: 2)), VpnSnapshotDisposition.stale);
    });

    test('detects a missed sequence and accepts authoritative resync', () {
      final gate = VpnSessionSnapshotGate()..accept(snapshot());
      final missed = snapshot(sequence: 3, version: 3);
      expect(gate.classify(missed), VpnSnapshotDisposition.gap);
      gate.acceptAuthoritative(missed);
      expect(gate.current, same(missed));
    });

    test('accepts a new runtime epoch after process recreation', () {
      final gate = VpnSessionSnapshotGate()..accept(snapshot(generation: 50, sequence: 20, version: 20));
      expect(gate.accept(snapshot(epoch: 'process-b')), isTrue);
    });

    test('Connected requires local startup evidence and an outbound', () {
      expect(snapshot(phase: VpnSessionPhase.connected).toCoreStatus(), isA<CoreStarting>());
      expect(snapshot(phase: VpnSessionPhase.connected, ready: true).provesConnected, isTrue);
      expect(snapshot(phase: VpnSessionPhase.connected, ready: true).toCoreStatus(), isA<CoreStarted>());
      expect(completeSnapshot(platformVpnValidated: false).provesConnected, isTrue);
    });

    test('transient CoreReady cannot replace Connected', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.connected, ready: true, sequence: 5, version: 5));
      expect(gate.classify(snapshot(sequence: 4, version: 4)), VpnSnapshotDisposition.stale);
    });

    test('newer transient CoreReady cannot regress Connected', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.connected, ready: true, sequence: 5, version: 5));
      expect(gate.classify(snapshot(sequence: 6, version: 6)), VpnSnapshotDisposition.stale);
    });

    test('stop progression after Connected is accepted', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.connected, ready: true, sequence: 5, version: 5));
      expect(
        gate.classify(snapshot(phase: VpnSessionPhase.stopRequested, sequence: 6, version: 6)),
        VpnSnapshotDisposition.accepted,
      );
    });

    test('a new generation may begin after a terminal phase', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.disconnected, sequence: 9, version: 9));
      final next = snapshot(generation: 2, phase: VpnSessionPhase.startRequested, sequence: 10, version: 10);
      expect(gate.accept(next), isTrue);
    });

    test('the same generation may connect after its preparation stop', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.disconnected, sequence: 9, version: 9));
      final start = snapshot(
        phase: VpnSessionPhase.startRequested,
        sequence: 10,
        version: 10,
        requestedAction: 'connect',
      );

      expect(gate.accept(start), isTrue);
      expect(gate.current, same(start));
    });

    test('authoritative Connected resync may recover a missed same-generation start', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.disconnected, sequence: 9, version: 9));
      final connected = snapshot(
        phase: VpnSessionPhase.connected,
        sequence: 12,
        version: 12,
        requestedAction: 'connect',
        ready: true,
      );

      expect(gate.classify(connected), VpnSnapshotDisposition.gap);
      gate.acceptAuthoritative(connected);
      expect(gate.current, same(connected));
    });

    test('invalid sequencing metadata is rejected', () {
      final gate = VpnSessionSnapshotGate();
      expect(gate.classify(snapshot(epoch: '')), VpnSnapshotDisposition.stale);
      expect(gate.classify(snapshot(sequence: 0)), VpnSnapshotDisposition.stale);
      expect(gate.classify(snapshot(version: 0)), VpnSnapshotDisposition.stale);
    });

    test('duplicate Connected is idempotent', () {
      final connected = snapshot(phase: VpnSessionPhase.connected, ready: true);
      final gate = VpnSessionSnapshotGate()..accept(connected);
      expect(gate.accept(connected), isFalse);
      expect(gate.current, same(connected));
    });

    for (final missingGate in <String, VpnSessionSnapshot Function()>{
      'coreReady': () => completeSnapshot(coreReady: false),
      'coreStarted': () => completeSnapshot(coreStarted: false),
      'commandEndpointReady': () => completeSnapshot(commandEndpointReady: false),
      'tunnelReady': () => completeSnapshot(tunnelReady: false),
      'protectSucceeded': () => completeSnapshot(protectSucceeded: false),
      'selectedOutbound': () => completeSnapshot(selectedOutboundId: ''),
    }.entries) {
      test('Connected is blocked without ${missingGate.key}', () {
        expect(missingGate.value().provesConnected, isFalse);
        expect(missingGate.value().toCoreStatus(), isA<CoreStarting>());
      });
    }

    for (final phase in <VpnSessionPhase>[
      VpnSessionPhase.permissionRequired,
      VpnSessionPhase.startRequested,
      VpnSessionPhase.startingPlatform,
      VpnSessionPhase.startingCore,
      VpnSessionPhase.waitingTun,
      VpnSessionPhase.verifying,
    ]) {
      test('$phase maps to Connecting', () {
        expect(snapshot(phase: phase).toCoreStatus(), isA<CoreStarting>());
      });
    }

    test('stale terminal error cannot replace a newer generation', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(generation: 2, phase: VpnSessionPhase.connected, ready: true, sequence: 8, version: 8));
      expect(
        gate.classify(snapshot(phase: VpnSessionPhase.failed, sequence: 9, version: 9)),
        VpnSnapshotDisposition.stale,
      );
    });

    test('event map parsing is deterministic', () {
      final parsed = VpnSessionSnapshot.fromEvent(const {
        'generation': '7',
        'runtimeEpoch': 'epoch',
        'sequenceNumber': 8,
        'snapshotVersion': 9,
        'phase': 'stop_requested',
        'recoverable': 'true',
      });
      expect(parsed.generation, 7);
      expect(parsed.phase, VpnSessionPhase.stopRequested);
      expect(parsed.recoverable, isTrue);
    });

    test('typed external stop source is preserved and classified', () {
      final parsed = VpnSessionSnapshot.fromEvent(const {
        'generation': 11,
        'runtimeEpoch': 'epoch',
        'sequenceNumber': 12,
        'snapshotVersion': 13,
        'phase': 'disconnected',
        'requestedAction': 'stop',
        'stopSource': 'notification',
      });

      expect(parsed.stopSource, VpnStopSource.notification);
      expect(parsed.isTerminalStop, isTrue);
      expect(parsed.isExternalIntentionalStop, isTrue);

      final systemStop = VpnSessionSnapshot.fromEvent(const {
        'generation': 12,
        'runtimeEpoch': 'ios-host-process',
        'sequenceNumber': 13,
        'snapshotVersion': 13,
        'phase': 'disconnected',
        'requestedAction': 'stop',
        'stopSource': 'system',
      });
      expect(systemStop.stopSource, VpnStopSource.system);
      expect(systemStop.isExternalIntentionalStop, isTrue);
      expect(
        snapshot(
          phase: VpnSessionPhase.disconnected,
          requestedAction: 'stop',
          stopSource: VpnStopSource.destroy,
        ).isExternalIntentionalStop,
        isFalse,
      );

      final replacement = VpnSessionSnapshot.fromEvent(const {
        'generation': 14,
        'runtimeEpoch': 'epoch',
        'sequenceNumber': 15,
        'snapshotVersion': 16,
        'phase': 'disconnected',
        'requestedAction': 'stop',
        'stopSource': 'replacement',
      });
      expect(replacement.stopSource, VpnStopSource.replacement);
      expect(replacement.isExternalIntentionalStop, isFalse);
    });

    test('late authoritative resync cannot roll back a newer event snapshot', () {
      final gate = VpnSessionSnapshotGate();
      final newerEvent = snapshot(
        generation: 22,
        sequence: 11,
        version: 11,
        phase: VpnSessionPhase.connected,
        ready: true,
      );
      final olderMethodResult = snapshot(generation: 22, sequence: 10, version: 10, phase: VpnSessionPhase.verifying);

      expect(gate.accept(newerEvent), isTrue);
      expect(gate.acceptResynced(olderMethodResult), isFalse);
      expect(gate.current, same(newerEvent));
      expect(gate.current?.toCoreStatus(), isA<CoreStarted>());
    });
  });
}

VpnSessionSnapshot completeSnapshot({
  bool coreReady = true,
  bool coreStarted = true,
  bool commandEndpointReady = true,
  bool tunnelReady = true,
  bool protectSucceeded = true,
  bool platformVpnValidated = true,
  String selectedOutboundId = 'opaque-outbound',
}) => VpnSessionSnapshot(
  generation: 1,
  runtimeEpoch: 'process-a',
  sequenceNumber: 1,
  snapshotVersion: 1,
  phase: VpnSessionPhase.connected,
  coreReady: coreReady,
  coreStarted: coreStarted,
  commandEndpointReady: commandEndpointReady,
  tunnelReady: tunnelReady,
  protectSucceeded: protectSucceeded,
  platformVpnValidated: platformVpnValidated,
  selectedOutboundId: selectedOutboundId,
);
