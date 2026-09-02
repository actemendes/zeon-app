import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/startup_failure_classification.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  group('startup outcome classification', () {
    test('successful current-generation native start is recovered and not an incident', () {
      final disposition = _classify(
        signal: StartupFailureSignal.grpcTransport,
        snapshot: _snapshot(phase: VpnSessionPhase.connected, connected: true),
      );

      expect(disposition, StartupOutcomeDisposition.recovered);
      expect(startupOutcomeIsIncident(disposition), isFalse);
    });

    test('current-generation authoritative FAILED remains a native start incident', () {
      final disposition = _classify(
        signal: StartupFailureSignal.backgroundSetup,
        snapshot: _snapshot(phase: VpnSessionPhase.failed, failureCode: 'StartService'),
      );

      expect(disposition, StartupOutcomeDisposition.nativeStartFailure);
      expect(startupOutcomeIsIncident(disposition), isTrue);
    });

    test('late failure from generation A is superseded by generation B', () {
      final disposition = _classify(
        operationCurrent: false,
        signal: StartupFailureSignal.nativeGate,
        snapshot: _snapshot(generation: 8, phase: VpnSessionPhase.failed),
      );

      expect(disposition, StartupOutcomeDisposition.superseded);
      expect(startupOutcomeIsIncident(disposition), isFalse);
    });

    test('transient control timeout followed by recovery is not a failure', () {
      final disposition = _classify(
        signal: StartupFailureSignal.grpcTransport,
        controlRecoverySucceeded: true,
        snapshot: _snapshot(phase: VpnSessionPhase.waitingTun),
      );

      expect(disposition, StartupOutcomeDisposition.recovered);
      expect(startupOutcomeIsIncident(disposition), isFalse);
    });

    test('failed control recovery plus native FAILED remains one real incident', () {
      final disposition = _classify(
        signal: StartupFailureSignal.grpcTransport,
        snapshot: _snapshot(phase: VpnSessionPhase.failed, failureCode: 'StartService'),
      );

      expect(disposition, StartupOutcomeDisposition.nativeStartFailure);
      expect(shouldReportStartupTelemetry(disposition, boundary: StartupTelemetryBoundary.internalSignal), isFalse);
      expect(shouldReportStartupTelemetry(disposition, boundary: StartupTelemetryBoundary.operationResult), isTrue);
    });

    test('background port timeout is control-channel failure, not native core failure', () {
      final disposition = _classify(
        signal: StartupFailureSignal.backgroundSetup,
        backgroundSetupFailure: BackgroundSetupFailure.controlPortTimeout,
        snapshot: _snapshot(phase: VpnSessionPhase.startingCore),
      );

      expect(disposition, StartupOutcomeDisposition.controlChannelFailure);
    });

    test('explicit stop or replacement cancels the old startup without an incident', () {
      for (final source in [VpnStopSource.flutter, VpnStopSource.replacement, VpnStopSource.notification]) {
        final disposition = _classify(
          signal: StartupFailureSignal.unknown,
          snapshot: _snapshot(phase: VpnSessionPhase.stopping, requestedAction: 'stop', stopSource: source),
        );
        expect(disposition, StartupOutcomeDisposition.intentionallyCancelled);
        expect(startupOutcomeIsIncident(disposition), isFalse);
      }
    });

    test('bare local CoreStatus cannot suppress a startup incident', () {
      // Mutable Dart CoreStatus is deliberately not an input to this model.
      expect(_classify(signal: StartupFailureSignal.coreResponse), StartupOutcomeDisposition.coreStartFailure);
    });
  });
}

StartupOutcomeDisposition _classify({
  bool operationCurrent = true,
  required StartupFailureSignal signal,
  BackgroundSetupFailure backgroundSetupFailure = BackgroundSetupFailure.none,
  VpnSessionSnapshot? snapshot,
  bool controlRecoverySucceeded = false,
}) => classifyStartupOutcome(
  StartupOutcomeEvidence(
    operationGeneration: 7,
    operationCurrent: operationCurrent,
    signal: signal,
    backgroundSetupFailure: backgroundSetupFailure,
    nativeSnapshot: snapshot,
    controlRecoverySucceeded: controlRecoverySucceeded,
  ),
);

VpnSessionSnapshot _snapshot({
  int generation = 7,
  required VpnSessionPhase phase,
  String requestedAction = 'connect',
  VpnStopSource stopSource = VpnStopSource.none,
  String failureCode = '',
  bool connected = false,
}) => VpnSessionSnapshot(
  generation: generation,
  runtimeEpoch: 'startup-test',
  sequenceNumber: 10,
  snapshotVersion: 10,
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
  selectedOutboundId: connected ? 'opaque' : '',
  failureCode: failureCode,
);
