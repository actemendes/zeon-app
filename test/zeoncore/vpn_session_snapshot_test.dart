import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

VpnSessionSnapshot snapshot({
  int generation = 1,
  int sequence = 1,
  int version = 1,
  String epoch = 'process-a',
  VpnSessionPhase phase = VpnSessionPhase.startingCore,
  bool ready = false,
}) => VpnSessionSnapshot(
  generation: generation,
  runtimeEpoch: epoch,
  sequenceNumber: sequence,
  snapshotVersion: version,
  phase: phase,
  coreReady: ready,
  coreStarted: ready,
  commandEndpointReady: ready,
  tunnelReady: ready,
  protectSucceeded: ready,
  platformVpnValidated: ready,
  selectedOutboundId: ready ? 'opaque-outbound' : '',
);

void main() {
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
      expect(gate.accept(snapshot(generation: 1, sequence: 1, version: 1, epoch: 'process-b')), isTrue);
    });

    test('Connected requires every platform gate and an outbound', () {
      expect(snapshot(phase: VpnSessionPhase.connected, ready: false).toCoreStatus(), isA<CoreStarting>());
      expect(snapshot(phase: VpnSessionPhase.connected, ready: true).provesConnected, isTrue);
      expect(snapshot(phase: VpnSessionPhase.connected, ready: true).toCoreStatus(), isA<CoreStarted>());
    });

    test('transient CoreReady cannot replace Connected', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.connected, ready: true, sequence: 5, version: 5));
      expect(
        gate.classify(snapshot(phase: VpnSessionPhase.startingCore, sequence: 4, version: 4)),
        VpnSnapshotDisposition.stale,
      );
    });

    test('newer transient CoreReady cannot regress Connected', () {
      final gate = VpnSessionSnapshotGate()
        ..accept(snapshot(phase: VpnSessionPhase.connected, ready: true, sequence: 5, version: 5));
      expect(
        gate.classify(snapshot(phase: VpnSessionPhase.startingCore, sequence: 6, version: 6)),
        VpnSnapshotDisposition.stale,
      );
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
      'platformVpnValidated': () => completeSnapshot(platformVpnValidated: false),
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
        gate.classify(snapshot(generation: 1, phase: VpnSessionPhase.failed, sequence: 9, version: 9)),
        VpnSnapshotDisposition.stale,
      );
    });

    test('event map parsing is deterministic', () {
      final parsed = VpnSessionSnapshot.fromEvent({
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
