import 'package:meta/meta.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

enum StartupFailureSignal {
  backgroundSetup,
  coreResponse,
  grpcTransport,
  nativeGate,
  permission,
  configuration,
  unknown,
}

enum StartupOutcomeDisposition {
  recovered,
  superseded,
  intentionallyCancelled,
  nativeStartFailure,
  controlChannelFailure,
  coreStartFailure,
  permissionFailure,
  configurationFailure,
  unknownFailure,
}

enum StartupTelemetryBoundary { internalSignal, operationResult }

@immutable
class StartupOutcomeEvidence {
  const StartupOutcomeEvidence({
    required this.operationGeneration,
    required this.operationCurrent,
    required this.signal,
    this.backgroundSetupFailure = BackgroundSetupFailure.none,
    this.nativeSnapshot,
    this.controlRecoverySucceeded = false,
  });

  final int operationGeneration;
  final bool operationCurrent;
  final StartupFailureSignal signal;
  final BackgroundSetupFailure backgroundSetupFailure;
  final VpnSessionSnapshot? nativeSnapshot;
  final bool controlRecoverySucceeded;
}

StartupOutcomeDisposition classifyStartupOutcome(StartupOutcomeEvidence evidence) {
  final snapshot = evidence.nativeSnapshot;
  final sameNativeGeneration = snapshot?.generation == evidence.operationGeneration;

  if (!evidence.operationCurrent || (snapshot != null && snapshot.generation > evidence.operationGeneration)) {
    return StartupOutcomeDisposition.superseded;
  }

  if (sameNativeGeneration &&
      snapshot!.requestedAction == 'stop' &&
      (snapshot.stopSource == VpnStopSource.flutter ||
          snapshot.stopSource == VpnStopSource.replacement ||
          snapshot.stopSource.isExternalIntentional)) {
    return StartupOutcomeDisposition.intentionallyCancelled;
  }

  if (evidence.controlRecoverySucceeded || (sameNativeGeneration && snapshot!.provesConnected)) {
    return StartupOutcomeDisposition.recovered;
  }

  if (sameNativeGeneration && snapshot!.phase == VpnSessionPhase.failed) {
    return StartupOutcomeDisposition.nativeStartFailure;
  }

  return switch (evidence.signal) {
    StartupFailureSignal.permission => StartupOutcomeDisposition.permissionFailure,
    StartupFailureSignal.configuration => StartupOutcomeDisposition.configurationFailure,
    StartupFailureSignal.coreResponse || StartupFailureSignal.nativeGate => StartupOutcomeDisposition.coreStartFailure,
    StartupFailureSignal.grpcTransport => StartupOutcomeDisposition.controlChannelFailure,
    StartupFailureSignal.backgroundSetup => switch (evidence.backgroundSetupFailure) {
      BackgroundSetupFailure.controlPortClosed ||
      BackgroundSetupFailure.controlPortTimeout ||
      BackgroundSetupFailure.controlPortSocketError ||
      BackgroundSetupFailure.controlPortOtherError ||
      BackgroundSetupFailure.commandEndpointTimeout => StartupOutcomeDisposition.controlChannelFailure,
      BackgroundSetupFailure.replacementTeardown => StartupOutcomeDisposition.coreStartFailure,
      BackgroundSetupFailure.none => StartupOutcomeDisposition.unknownFailure,
    },
    StartupFailureSignal.unknown => StartupOutcomeDisposition.unknownFailure,
  };
}

bool startupOutcomeIsIncident(StartupOutcomeDisposition disposition) => switch (disposition) {
  StartupOutcomeDisposition.recovered ||
  StartupOutcomeDisposition.superseded ||
  StartupOutcomeDisposition.intentionallyCancelled => false,
  _ => true,
};

bool shouldReportStartupTelemetry(
  StartupOutcomeDisposition disposition, {
  required StartupTelemetryBoundary boundary,
}) => startupOutcomeIsIncident(disposition) && boundary == StartupTelemetryBoundary.operationResult;
