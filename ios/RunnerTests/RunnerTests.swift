import Flutter
import NetworkExtension
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testSessionGenerationIsMonotonic() {
    let manager = VPNManager.shared
    let next = manager.currentSessionGeneration() + 10

    XCTAssertEqual(manager.setSessionGeneration(next), next)
    XCTAssertTrue(manager.isCurrentGeneration(next))
    XCTAssertEqual(manager.setSessionGeneration(next - 1), next)
    XCTAssertFalse(manager.isCurrentGeneration(next - 1))
  }

  func testNewGenerationCannotInheritCoreReadiness() {
    let manager = VPNManager.shared
    let next = manager.currentSessionGeneration() + 10

    XCTAssertEqual(manager.setSessionGeneration(next), next)
    XCTAssertFalse(manager.isCoreReadyForCurrentGeneration())
  }

  func testEmptyAlertIsNotEmitted() {
    XCTAssertFalse(
      AlertsEventHandler.shouldEmitAlert(VPNManagerAlert(alert: nil, message: nil))
    )
    XCTAssertFalse(
      AlertsEventHandler.shouldEmitAlert(VPNManagerAlert(alert: nil, message: " \n\t "))
    )
  }

  func testMeaningfulAlertIsEmitted() {
    XCTAssertTrue(
      AlertsEventHandler.shouldEmitAlert(
        VPNManagerAlert(alert: .StartService, message: nil)
      )
    )
    XCTAssertTrue(
      AlertsEventHandler.shouldEmitAlert(
        VPNManagerAlert(alert: nil, message: "Core failed")
      )
    )
  }

  func testLateDisconnectingFromInactiveStatePreservesNewConnectIntent() {
    let intent = VPNManager.intentAfterStatusTransition(
      previousStatus: .disconnected,
      status: .disconnecting,
      requestedAction: "connect",
      stopSource: ""
    )

    XCTAssertEqual(intent.requestedAction, "connect")
    XCTAssertEqual(intent.stopSource, "replacement")
  }

  func testDisconnectingActiveTunnelIsClassifiedAsSystemStop() {
    let intent = VPNManager.intentAfterStatusTransition(
      previousStatus: .connected,
      status: .disconnecting,
      requestedAction: "connect",
      stopSource: ""
    )

    XCTAssertEqual(intent.requestedAction, "stop")
    XCTAssertEqual(intent.stopSource, "system")
  }

  func testExplicitReplacementStopKeepsReplacementSource() {
    let intent = VPNManager.intentAfterStatusTransition(
      previousStatus: .connected,
      status: .disconnecting,
      requestedAction: "stop",
      stopSource: "replacement"
    )

    XCTAssertEqual(intent.requestedAction, "stop")
    XCTAssertEqual(intent.stopSource, "replacement")
  }

  func testLateActiveStateDoesNotResurrectAcceptedStop() {
    let intent = VPNManager.intentAfterStatusTransition(
      previousStatus: .connected,
      status: .reasserting,
      requestedAction: "stop",
      stopSource: "flutter"
    )

    XCTAssertEqual(intent.requestedAction, "stop")
    XCTAssertEqual(intent.stopSource, "flutter")
    XCTAssertEqual(
      VPNManager.sessionPhase(
        status: .connected,
        generation: 42,
        coreReady: true,
        requestedAction: "stop"
      ),
      "stopping"
    )
  }

  func testActiveStateFromInactiveStateIsClassifiedAsSystemStart() {
    let intent = VPNManager.intentAfterStatusTransition(
      previousStatus: .disconnected,
      status: .connecting,
      requestedAction: "stop",
      stopSource: "flutter"
    )

    XCTAssertEqual(intent.requestedAction, "connect")
    XCTAssertEqual(intent.stopSource, "")
  }

  func testDelayedStartWhileExplicitStopCancellationIsPendingCannotResurrectConnect() {
    let intent = VPNManager.intentAfterStatusTransition(
      previousStatus: .disconnected,
      status: .connecting,
      requestedAction: "stop",
      stopSource: "flutter",
      stopCancellationPending: true
    )

    XCTAssertEqual(intent.requestedAction, "stop")
    XCTAssertEqual(intent.stopSource, "flutter")
  }

  func testInactiveTunnelWithConnectIntentUsesStartRequestedPhase() {
    XCTAssertEqual(
      VPNManager.sessionPhase(
        status: .disconnected,
        generation: 42,
        coreReady: false,
        requestedAction: "connect"
      ),
      "start_requested"
    )
    XCTAssertEqual(
      VPNManager.sessionPhase(
        status: .disconnected,
        generation: 42,
        coreReady: false,
        requestedAction: "stop"
      ),
      "disconnected"
    )

  }

  func testPreparationGenerationRemainsInactiveUntilConnectIsRequested() {
    let manager = VPNManager.shared
    let next = manager.currentSessionGeneration() + 10

    XCTAssertEqual(
      manager.setSessionGeneration(next, requestedAction: "prepare"),
      next
    )
    XCTAssertEqual(manager.sessionSnapshot()["requestedAction"] as? String, "prepare")
    XCTAssertEqual(
      VPNManager.sessionPhase(
        status: .disconnected,
        generation: next,
        coreReady: false,
        requestedAction: "prepare"
      ),
      "disconnected"
    )
    XCTAssertEqual(
      VPNManager.sessionPhase(
        status: .invalid,
        generation: next,
        coreReady: false,
        requestedAction: "prepare"
      ),
      "disconnected"
    )

  }

  func testSameGenerationPromotesPreparationToConnect() {
    let manager = VPNManager.shared
    let next = manager.currentSessionGeneration() + 10

    XCTAssertEqual(
      manager.setSessionGeneration(next, requestedAction: "prepare"),
      next
    )
    XCTAssertEqual(manager.setSessionGeneration(next), next)
    XCTAssertEqual(manager.sessionSnapshot()["requestedAction"] as? String, "connect")
    XCTAssertEqual(
      VPNManager.sessionPhase(
        status: .disconnected,
        generation: next,
        coreReady: false,
        requestedAction: "connect"
      ),
      "start_requested"
    )
  }

  func testColdActiveTunnelDefersPreparationGenerationForProviderAdoption() {
    XCTAssertTrue(
      VPNManager.shouldDeferPreparationGeneration(
        currentGeneration: 0,
        requestedGeneration: 42,
        status: .connected,
        providerStatusRequestInFlight: false
      )
    )
    XCTAssertTrue(
      VPNManager.shouldDeferPreparationGeneration(
        currentGeneration: 0,
        requestedGeneration: 42,
        status: .disconnected,
        providerStatusRequestInFlight: true
      )
    )
    XCTAssertFalse(
      VPNManager.shouldDeferPreparationGeneration(
        currentGeneration: 0,
        requestedGeneration: 42,
        status: .disconnected,
        providerStatusRequestInFlight: false
      )
    )
    XCTAssertTrue(
      VPNManager.shouldDeferPreparationGeneration(
        currentGeneration: 41,
        requestedGeneration: 42,
        status: .connected,
        providerStatusRequestInFlight: true
      )
    )
  }

  func testSystemStopCannotBeRelabeledOrResurrectedByLateConnect() {
    let systemStop = VPNManager.intentAfterStatusTransition(
      previousStatus: .connected,
      status: .disconnecting,
      requestedAction: "connect",
      stopSource: ""
    )
    let replacementAttempt = VPNManager.intentAfterInternalReplacementStopRequest(
      requestedAction: systemStop.requestedAction,
      stopSource: systemStop.stopSource
    )
    let lateConnect = VPNManager.intentAfterConnectRequest(
      requestedAction: replacementAttempt.requestedAction,
      stopSource: replacementAttempt.stopSource,
      allowInternalReplacementPromotion: true
    )

    XCTAssertFalse(replacementAttempt.accepted)
    XCTAssertEqual(replacementAttempt.requestedAction, "stop")
    XCTAssertEqual(replacementAttempt.stopSource, "system")
    XCTAssertFalse(lateConnect.accepted)
    XCTAssertEqual(lateConnect.requestedAction, "stop")
    XCTAssertEqual(lateConnect.stopSource, "system")
  }

  func testInternalReplacementStopCanExplicitlyPromoteBackToConnect() {
    let replacementStop = VPNManager.intentAfterInternalReplacementStopRequest(
      requestedAction: "connect",
      stopSource: ""
    )
    let ordinaryConnect = VPNManager.intentAfterConnectRequest(
      requestedAction: replacementStop.requestedAction,
      stopSource: replacementStop.stopSource,
      allowInternalReplacementPromotion: false
    )
    let replacementConnect = VPNManager.intentAfterConnectRequest(
      requestedAction: replacementStop.requestedAction,
      stopSource: replacementStop.stopSource,
      allowInternalReplacementPromotion: true
    )

    XCTAssertTrue(replacementStop.accepted)
    XCTAssertEqual(replacementStop.requestedAction, "stop")
    XCTAssertEqual(replacementStop.stopSource, "replacement")
    XCTAssertFalse(ordinaryConnect.accepted)
    XCTAssertEqual(ordinaryConnect.requestedAction, "stop")
    XCTAssertEqual(ordinaryConnect.stopSource, "replacement")
    XCTAssertTrue(replacementConnect.accepted)
    XCTAssertEqual(replacementConnect.requestedAction, "connect")
    XCTAssertEqual(replacementConnect.stopSource, "")
  }

  func testPreparationCannotDemoteAcceptedConnectOrStop() {
    let connect = VPNManager.intentAfterPrepareRequest(
      requestedAction: "connect",
      stopSource: ""
    )
    let stop = VPNManager.intentAfterPrepareRequest(
      requestedAction: "stop",
      stopSource: "system"
    )

    XCTAssertTrue(connect.accepted)
    XCTAssertEqual(connect.requestedAction, "connect")
    XCTAssertEqual(connect.stopSource, "")
    XCTAssertFalse(stop.accepted)
    XCTAssertEqual(stop.requestedAction, "stop")
    XCTAssertEqual(stop.stopSource, "system")
  }

  func testPreemptiveStopGenerationAlwaysRebasesAboveNativeOwner() {
    XCTAssertEqual(
      VPNManager.preemptiveStopGeneration(
        currentGeneration: 10_000,
        requestedGeneration: 9_000
      ),
      10_001
    )
    XCTAssertEqual(
      VPNManager.preemptiveStopGeneration(
        currentGeneration: 10_000,
        requestedGeneration: 12_000
      ),
      12_000
    )
  }

  func testPreemptiveStopAtomicallyOwnsItsAcceptedGeneration() {
    let manager = VPNManager.shared
    let connectGeneration = manager.currentSessionGeneration() + 10
    XCTAssertEqual(manager.setSessionGeneration(connectGeneration), connectGeneration)

    let stopGeneration = manager.reservePreemptiveStopGeneration(
      connectGeneration,
      source: "flutter"
    )
    let stoppedSnapshot = manager.sessionSnapshot()

    XCTAssertGreaterThan(stopGeneration, connectGeneration)
    XCTAssertEqual((stoppedSnapshot["generation"] as? NSNumber)?.int64Value, stopGeneration)
    XCTAssertEqual(stoppedSnapshot["requestedAction"] as? String, "stop")
    XCTAssertEqual(stoppedSnapshot["stopSource"] as? String, "flutter")

    let newerConnect = stopGeneration + 1
    XCTAssertEqual(manager.setSessionGeneration(newerConnect), newerConnect)
    XCTAssertEqual(manager.sessionSnapshot()["requestedAction"] as? String, "connect")
  }

  func testPersistedStopGenerationPreservesProviderConfiguration() {
    let updated = VPNManager.providerConfigurationByUpdatingGeneration(
      [
        "Config": "/tmp/runtime.json",
        "GrpcServiceModePort": 17179,
        "Generation": NSNumber(value: 41),
      ],
      generation: 42
    )

    XCTAssertEqual(updated["Config"] as? String, "/tmp/runtime.json")
    XCTAssertEqual(updated["GrpcServiceModePort"] as? Int, 17179)
    XCTAssertEqual((updated["Generation"] as? NSNumber)?.int64Value, 42)
  }

  func testExactPersistedProviderProofAdoptsSettingsStartAfterStop() {
    let disposition = VPNManager.providerSessionStatusDisposition(
      connectionIsCurrent: true,
      generationIsCurrent: true,
      expectedGeneration: 42,
      providerGeneration: 42,
      providerCoreStarted: true,
      requestedAction: "stop",
      stopCancellationPending: true,
      stopReachedStableInactive: true
    )

    XCTAssertEqual(disposition, .adopt)
  }

  func testDelayedOldGenerationStartIsRejectedByPendingStopTombstone() {
    let disposition = VPNManager.providerSessionStatusDisposition(
      connectionIsCurrent: true,
      generationIsCurrent: true,
      expectedGeneration: 42,
      providerGeneration: 41,
      providerCoreStarted: true,
      requestedAction: "stop",
      stopCancellationPending: true,
      stopReachedStableInactive: true
    )

    XCTAssertEqual(disposition, .rejectPendingStop)
  }

  func testActiveCallbackBeforeStableStopCannotMasqueradeAsSettingsStart() {
    let disposition = VPNManager.providerSessionStatusDisposition(
      connectionIsCurrent: true,
      generationIsCurrent: true,
      expectedGeneration: 42,
      providerGeneration: 42,
      providerCoreStarted: true,
      requestedAction: "stop",
      stopCancellationPending: true,
      stopReachedStableInactive: false
    )

    XCTAssertEqual(disposition, .rejectPendingStop)
  }

  func testBootstrapPreparationAdoptsProviderAlreadyLaunchedWithOlderGeneration() {
    let adopted = VPNManager.providerSessionStatusDisposition(
      connectionIsCurrent: true,
      generationIsCurrent: true,
      expectedGeneration: 52,
      providerGeneration: 41,
      providerCoreStarted: true,
      requestedAction: "connect",
      stopCancellationPending: false,
      stopReachedStableInactive: false,
      bootstrapPreparationPending: true
    )
    let ordinaryMismatch = VPNManager.providerSessionStatusDisposition(
      connectionIsCurrent: true,
      generationIsCurrent: true,
      expectedGeneration: 52,
      providerGeneration: 41,
      providerCoreStarted: true,
      requestedAction: "connect",
      stopCancellationPending: false,
      stopReachedStableInactive: false,
      bootstrapPreparationPending: false
    )

    XCTAssertEqual(adopted, .adopt)
    XCTAssertEqual(ordinaryMismatch, .ignore)
    XCTAssertEqual(
      VPNManager.adoptedProviderGeneration(
        expectedGeneration: 52,
        providerGeneration: 41,
        bootstrapPreparationPending: true
      ),
      52
    )
  }

  func testNewerProviderGenerationIsAdoptedForAProvenExternalStart() {
    let disposition = VPNManager.providerSessionStatusDisposition(
      connectionIsCurrent: true,
      generationIsCurrent: true,
      expectedGeneration: 41,
      providerGeneration: 52,
      providerCoreStarted: true,
      requestedAction: "connect",
      stopCancellationPending: false,
      stopReachedStableInactive: false
    )

    XCTAssertEqual(disposition, .adopt)
    XCTAssertEqual(
      VPNManager.adoptedProviderGeneration(
        expectedGeneration: 41,
        providerGeneration: 52,
        bootstrapPreparationPending: false
      ),
      52
    )
  }

  func testPrepareSaveRebuildsMissingOrInvalidTunnelProtocol() {
    let providerConfiguration: [String: Any] = [
      "Config": "/tmp/runtime.json",
      "Generation": NSNumber(value: 42),
    ]
    let fromMissing = VPNManager.tunnelProtocolForSaving(
      existingProtocol: nil,
      providerBundleIdentifier: "com.zeon.test.PacketTunnel",
      providerConfiguration: providerConfiguration
    )
    let invalidProtocol = NEVPNProtocolIKEv2()
    let fromInvalid = VPNManager.tunnelProtocolForSaving(
      existingProtocol: invalidProtocol,
      providerBundleIdentifier: "com.zeon.test.PacketTunnel",
      providerConfiguration: providerConfiguration
    )

    XCTAssertEqual(fromMissing.providerBundleIdentifier, "com.zeon.test.PacketTunnel")
    XCTAssertEqual(fromMissing.serverAddress, "localhost")
    XCTAssertEqual(fromMissing.providerConfiguration?["Config"] as? String, "/tmp/runtime.json")
    XCTAssertFalse(fromInvalid === invalidProtocol)
    XCTAssertEqual(fromInvalid.providerBundleIdentifier, "com.zeon.test.PacketTunnel")
    XCTAssertEqual((fromInvalid.providerConfiguration?["Generation"] as? NSNumber)?.int64Value, 42)
  }

  func testPrepareSavePreservesValidTunnelProtocolState() {
    let existing = NETunnelProviderProtocol()
    existing.providerBundleIdentifier = "com.zeon.legacy.PacketTunnel"
    existing.serverAddress = "legacy-host"
    existing.providerConfiguration = ["Existing": "preserved"]

    let repaired = VPNManager.tunnelProtocolForSaving(
      existingProtocol: existing,
      providerBundleIdentifier: "com.zeon.test.PacketTunnel"
    )

    XCTAssertTrue(repaired === existing)
    XCTAssertEqual(repaired.providerBundleIdentifier, "com.zeon.test.PacketTunnel")
    XCTAssertEqual(repaired.serverAddress, "legacy-host")
    XCTAssertEqual(repaired.providerConfiguration?["Existing"] as? String, "preserved")
  }

  func testTunnelManagerSelectionPrefersActiveExactThenValidLegacy() {
    let candidates: [(isExact: Bool, isValid: Bool, isActive: Bool)] = [
      (false, false, true),
      (true, true, false),
      (false, true, true),
      (true, true, true),
    ]
    let withoutExact: [(isExact: Bool, isValid: Bool, isActive: Bool)] = [
      (false, false, true),
      (false, true, false),
      (false, true, true),
    ]
    let inactiveExactVersusActiveLegacy: [(isExact: Bool, isValid: Bool, isActive: Bool)] = [
      (true, true, false),
      (false, true, true),
    ]
    let inactiveExactVersusActiveInvalid: [(isExact: Bool, isValid: Bool, isActive: Bool)] = [
      (true, true, false),
      (false, false, true),
    ]

    XCTAssertEqual(VPNManager.preferredTunnelManagerIndex(candidates), 3)
    XCTAssertEqual(VPNManager.preferredTunnelManagerIndex(withoutExact), 2)
    XCTAssertEqual(VPNManager.preferredTunnelManagerIndex(inactiveExactVersusActiveLegacy), 1)
    XCTAssertEqual(VPNManager.preferredTunnelManagerIndex(inactiveExactVersusActiveInvalid), 1)
    XCTAssertNil(VPNManager.preferredTunnelManagerIndex([]))
  }

  func testTunnelManagerCleanupRemovesOnlyInactiveNonSelectedDuplicates() {
    let candidates: [(isExact: Bool, isValid: Bool, isActive: Bool)] = [
      (true, true, true),
      (false, true, false),
      (false, true, true),
      (true, true, false),
      (false, false, false),
    ]

    XCTAssertEqual(
      VPNManager.inactiveDuplicateManagerIndices(candidates, selectedIndex: 0),
      [1, 3, 4]
    )
    XCTAssertEqual(
      VPNManager.inactiveDuplicateManagerIndices(candidates, selectedIndex: 3),
      [1, 4]
    )
    XCTAssertTrue(
      VPNManager.inactiveDuplicateManagerIndices(candidates, selectedIndex: 99).isEmpty
    )
  }

  func testBootstrapPreparationDefersActiveOwnerImmediatelyBeforeSave() {
    let owningStatuses: [NEVPNStatus] = [
      .connected,
      .connecting,
      .reasserting,
      .disconnecting,
    ]

    for status in owningStatuses {
      XCTAssertTrue(
        VPNManager.shouldDeferBootstrapPreparationAfterReload(
          bootstrapPreparation: true,
          generationIsCurrent: true,
          status: status
        ),
        "expected bootstrap prepare to defer for status \(status.rawValue)"
      )
      XCTAssertFalse(
        VPNManager.shouldDeferBootstrapPreparationAfterReload(
          bootstrapPreparation: false,
          generationIsCurrent: true,
          status: status
        ),
        "an explicit Connect must not defer for status \(status.rawValue)"
      )
      XCTAssertFalse(
        VPNManager.shouldDeferBootstrapPreparationAfterReload(
          bootstrapPreparation: true,
          generationIsCurrent: false,
          status: status
        ),
        "a stale generation must not be treated as an accepted bootstrap"
      )
    }

    for status in [NEVPNStatus.disconnected, .invalid] {
      XCTAssertFalse(
        VPNManager.shouldDeferBootstrapPreparationAfterReload(
          bootstrapPreparation: true,
          generationIsCurrent: true,
          status: status
        ),
        "inactive bootstrap prepare must still create or repair preferences"
      )
    }
  }

}
