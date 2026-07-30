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
  });
}
