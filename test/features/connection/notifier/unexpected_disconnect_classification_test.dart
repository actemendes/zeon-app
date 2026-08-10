import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  group('unexpected disconnect classification', () {
    test('explicit manual stop intent suppresses orderly completion', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: true,
          hasFailure: false,
          hasExpectedStopIntent: true,
          nativeSnapshot: null,
        ),
        isFalse,
      );
    });

    test('explicit restart intent suppresses its intermediate disconnect', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: true,
          hasFailure: false,
          hasExpectedStopIntent: true,
          nativeSnapshot: _snapshot(
            phase: VpnSessionPhase.disconnected,
            requestedAction: 'stop',
            stopSource: VpnStopSource.replacement,
          ),
        ),
        isFalse,
      );
    });

    test('authoritative Android stop suppresses orderly completion', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: true,
          hasFailure: false,
          hasExpectedStopIntent: false,
          nativeSnapshot: _snapshot(
            phase: VpnSessionPhase.stopping,
            requestedAction: 'stop',
            stopSource: VpnStopSource.notification,
          ),
        ),
        isFalse,
      );
    });

    test('real unexpected stop remains reportable without stop evidence', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: true,
          hasFailure: false,
          hasExpectedStopIntent: false,
          nativeSnapshot: _snapshot(phase: VpnSessionPhase.disconnected),
        ),
        isTrue,
      );
    });

    test('bare local Disconnecting/CoreStopping projection cannot suppress', () {
      // Neither mutable local status is an input to this classifier. With no
      // operation intent or native stop proof, the outage remains visible.
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: true,
          hasFailure: false,
          hasExpectedStopIntent: false,
          nativeSnapshot: null,
        ),
        isTrue,
      );
    });

    test('native FAILED remains reportable during restart', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: true,
          hasFailure: false,
          hasExpectedStopIntent: true,
          nativeSnapshot: _snapshot(
            phase: VpnSessionPhase.failed,
            requestedAction: 'connect',
            failureCode: 'START_SERVICE',
          ),
        ),
        isTrue,
      );
    });

    test('connection failure remains reportable during expected stop', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: false,
          hasFailure: true,
          hasExpectedStopIntent: true,
          nativeSnapshot: null,
        ),
        isTrue,
      );
    });

    test('service destruction is not treated as an expected stop', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: true,
          expectedRunning: true,
          hasFailure: false,
          hasExpectedStopIntent: false,
          nativeSnapshot: _snapshot(
            phase: VpnSessionPhase.disconnected,
            requestedAction: 'stop',
            stopSource: VpnStopSource.destroy,
          ),
        ),
        isTrue,
      );
    });

    test('never reports a disconnect before the tunnel was up', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          wasUpBefore: false,
          expectedRunning: true,
          hasFailure: true,
          hasExpectedStopIntent: false,
          nativeSnapshot: _snapshot(
            phase: VpnSessionPhase.failed,
            requestedAction: 'connect',
            failureCode: 'START_SERVICE',
          ),
        ),
        isFalse,
        reason: 'startup failures are reported by connection_failure/startup telemetry instead',
      );
    });
  });
}

VpnSessionSnapshot _snapshot({
  required VpnSessionPhase phase,
  String requestedAction = '',
  VpnStopSource stopSource = VpnStopSource.none,
  String failureCode = '',
}) {
  return VpnSessionSnapshot(
    generation: 7,
    runtimeEpoch: 'test-runtime',
    sequenceNumber: 11,
    snapshotVersion: 13,
    phase: phase,
    requestedAction: requestedAction,
    stopSource: stopSource,
    failureCode: failureCode,
  );
}
