import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  group('transport close classification', () {
    test('orderly stop and foreground teardown are expected', () {
      for (final intent in [TransportCloseIntent.stop, TransportCloseIntent.foregroundClose]) {
        expect(
          _classify(intent: intent, stage: TransportCloseStage.teardown),
          TransportCloseDisposition.expectedTeardown,
        );
      }
    });

    test('restart replacement teardown is expected', () {
      expect(
        _classify(intent: TransportCloseIntent.restartReplacement, stage: TransportCloseStage.teardown),
        TransportCloseDisposition.expectedTeardown,
      );
    });

    test('authoritative intentional native stop is expected', () {
      expect(
        _classify(
          nativeSnapshot: _snapshot(
            phase: VpnSessionPhase.stopping,
            requestedAction: 'stop',
            stopSource: VpnStopSource.flutter,
          ),
        ),
        TransportCloseDisposition.expectedTeardown,
      );
    });

    test('active background core plus restored control channel is recovered', () {
      expect(
        _classify(backgroundCoreActive: true, controlRecoverySucceeded: true),
        TransportCloseDisposition.recovered,
      );
    });

    test('authoritative connected session plus restored control channel is recovered', () {
      expect(
        _classify(
          controlRecoverySucceeded: true,
          nativeSnapshot: _snapshot(phase: VpnSessionPhase.connected, connected: true),
        ),
        TransportCloseDisposition.recovered,
      );
    });

    test('inactive background core and failed recovery remains a real incident', () {
      expect(_classify(), TransportCloseDisposition.realFailure);
    });

    test('explicit ConnectionFailure remains reportable', () {
      expect(
        _classify(intent: TransportCloseIntent.stop, stage: TransportCloseStage.teardown, explicitFailure: true),
        TransportCloseDisposition.realFailure,
      );
    });

    test('authoritative native FAILED remains reportable', () {
      expect(
        _classify(
          nativeSnapshot: _snapshot(phase: VpnSessionPhase.failed, requestedAction: 'connect'),
        ),
        TransportCloseDisposition.realFailure,
      );
    });

    test('internal native stop does not masquerade as orderly teardown', () {
      expect(
        _classify(
          nativeSnapshot: _snapshot(
            phase: VpnSessionPhase.disconnected,
            requestedAction: 'stop',
            stopSource: VpnStopSource.internal,
          ),
        ),
        TransportCloseDisposition.realFailure,
      );
    });

    test('bare or stale local CoreStatus cannot suppress a real incident', () {
      // Mutable Dart CoreStatus is deliberately not an input. Without an
      // operation intent, native proof, and successful recovery, it is real.
      expect(_classify(), TransportCloseDisposition.realFailure);
    });

    test('background reachability alone cannot claim control recovery', () {
      expect(_classify(backgroundCoreActive: true), TransportCloseDisposition.realFailure);
    });

    test('superseded operation is not attributed to a newer failed session', () {
      expect(
        _classify(
          operationCurrent: false,
          nativeSnapshot: _snapshot(generation: 8, phase: VpnSessionPhase.failed, requestedAction: 'connect'),
        ),
        TransportCloseDisposition.expectedTeardown,
      );
    });
  });
}

TransportCloseDisposition _classify({
  TransportCloseIntent intent = TransportCloseIntent.none,
  TransportCloseStage stage = TransportCloseStage.listener,
  bool operationCurrent = true,
  bool backgroundCoreActive = false,
  bool controlRecoverySucceeded = false,
  VpnSessionSnapshot? nativeSnapshot,
  bool explicitFailure = false,
}) => classifyTransportClose(
  intent: intent,
  stage: stage,
  operationGeneration: 7,
  operationCurrent: operationCurrent,
  backgroundCoreActive: backgroundCoreActive,
  controlRecoverySucceeded: controlRecoverySucceeded,
  nativeSnapshot: nativeSnapshot,
  explicitFailure: explicitFailure,
);

VpnSessionSnapshot _snapshot({
  int generation = 7,
  required VpnSessionPhase phase,
  String requestedAction = '',
  VpnStopSource stopSource = VpnStopSource.none,
  bool connected = false,
}) => VpnSessionSnapshot(
  generation: generation,
  runtimeEpoch: 'test-runtime',
  sequenceNumber: 11,
  snapshotVersion: 13,
  phase: phase,
  requestedAction: requestedAction,
  stopSource: stopSource,
  coreReady: connected,
  coreStarted: connected,
  commandEndpointReady: connected,
  tunnelReady: connected,
  protectSucceeded: connected,
  dataPlaneReady: connected,
  platformVpnValidated: connected,
  selectedOutboundId: connected ? 'opaque-outbound' : '',
);
