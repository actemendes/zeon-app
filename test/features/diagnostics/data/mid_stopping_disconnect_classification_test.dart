import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  group('authoritative stop evidence', () {
    test('explicit Flutter stop is expected', () {
      expect(
        nativeSnapshotIndicatesExplicitStop(
          _snapshot(phase: VpnSessionPhase.stopRequested, requestedAction: 'stop', stopSource: VpnStopSource.flutter),
        ),
        isTrue,
      );
    });

    test('replacement stop is expected', () {
      expect(
        nativeSnapshotIndicatesExplicitStop(
          _snapshot(
            phase: VpnSessionPhase.disconnected,
            requestedAction: 'stop',
            stopSource: VpnStopSource.replacement,
          ),
        ),
        isTrue,
      );
    });

    test('FAILED is not suppressed even when it retains stop metadata', () {
      expect(
        nativeSnapshotIndicatesExplicitStop(
          _snapshot(phase: VpnSessionPhase.failed, requestedAction: 'stop', stopSource: VpnStopSource.flutter),
        ),
        isFalse,
      );
    });

    test('service destruction remains unexpected', () {
      expect(
        nativeSnapshotIndicatesExplicitStop(
          _snapshot(phase: VpnSessionPhase.disconnected, requestedAction: 'stop', stopSource: VpnStopSource.destroy),
        ),
        isFalse,
      );
    });

    test('unknown stop source remains unexpected', () {
      expect(
        nativeSnapshotIndicatesExplicitStop(
          _snapshot(phase: VpnSessionPhase.stopping, requestedAction: 'stop', stopSource: VpnStopSource.unknown),
        ),
        isFalse,
      );
    });
  });
}

VpnSessionSnapshot _snapshot({
  required VpnSessionPhase phase,
  required String requestedAction,
  required VpnStopSource stopSource,
}) {
  return VpnSessionSnapshot(
    generation: 3,
    runtimeEpoch: 'test-runtime',
    sequenceNumber: 5,
    snapshotVersion: 8,
    phase: phase,
    requestedAction: requestedAction,
    stopSource: stopSource,
  );
}
