import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/diagnostics/data/error_report_controller.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  group('startup failure classification', () {
    test('no authoritative snapshot is not a failure', () {
      expect(startupSnapshotIndicatesFailedStart(null), isFalse);
    });

    test('ordinary cold-start idle snapshot is not a failure', () {
      expect(startupSnapshotIndicatesFailedStart(_snapshot(phase: VpnSessionPhase.idle)), isFalse);
    });

    test('bare terminal stop is not proof of a failed start', () {
      expect(
        startupSnapshotIndicatesFailedStart(_snapshot(phase: VpnSessionPhase.disconnected, requestedAction: 'stop')),
        isFalse,
      );
    });

    test('authoritative failed connect remains reportable', () {
      expect(
        startupSnapshotIndicatesFailedStart(
          _snapshot(phase: VpnSessionPhase.failed, requestedAction: 'connect', failureCode: 'START_SERVICE'),
        ),
        isTrue,
      );
    });

    test('failed teardown is not misclassified as a startup failure', () {
      expect(
        startupSnapshotIndicatesFailedStart(
          _snapshot(phase: VpnSessionPhase.failed, requestedAction: 'stop', failureCode: 'teardown_timeout'),
        ),
        isFalse,
      );
    });

    test('generation zero cannot prove a current start attempt', () {
      expect(
        startupSnapshotIndicatesFailedStart(
          _snapshot(
            generation: 0,
            phase: VpnSessionPhase.failed,
            requestedAction: 'connect',
            failureCode: 'START_SERVICE',
          ),
        ),
        isFalse,
      );
    });
  });
}

VpnSessionSnapshot _snapshot({
  int generation = 4,
  required VpnSessionPhase phase,
  String requestedAction = '',
  String failureCode = '',
}) {
  return VpnSessionSnapshot(
    generation: generation,
    runtimeEpoch: 'test-runtime',
    sequenceNumber: 6,
    snapshotVersion: 9,
    phase: phase,
    requestedAction: requestedAction,
    failureCode: failureCode,
    failureOwner: failureCode.isEmpty ? '' : 'android_service',
  );
}
