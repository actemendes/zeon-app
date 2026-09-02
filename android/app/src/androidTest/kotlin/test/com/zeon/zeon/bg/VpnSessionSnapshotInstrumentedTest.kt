package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.VpnSessionPhase
import com.zeon.zeon.bg.VpnSessionSnapshot
import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.bg.VpnSessionSnapshotCoordinator
import com.zeon.zeon.bg.phaseAfterCommandEndpointReady
import com.zeon.zeon.bg.VpnStopSource
import com.zeon.zeon.bg.VpnLifecycleIntentCoordinator
import com.zeon.zeon.bg.CoreProcessOwnerCoordinator
import com.zeon.zeon.bg.TunDescriptorOwner
import com.zeon.zeon.Settings
import com.zeon.zeon.bg.BoxService
import com.zeon.zeon.bg.selectedOutboundRequiresDataPlaneRevalidation
import com.zeon.zeon.bg.selectedOutboundRevalidationAction
import com.zeon.zeon.bg.SelectedOutboundRevalidationAction
import kotlinx.coroutines.delay

class VpnSessionSnapshotInstrumentedTest {
    private fun snapshot(
        phase: VpnSessionPhase,
        ready: Boolean,
        outbound: String = if (ready) "opaque" else "",
        platformValidated: Boolean = ready,
        dataPlaneReady: Boolean = ready,
    ) = VpnSessionSnapshot(
        generation = 10L,
        runtimeEpoch = "test",
        sequenceNumber = 1L,
        snapshotVersion = 1L,
        phase = phase,
        coreReady = ready,
        coreStarted = ready,
        commandEndpointReady = ready,
        tunnelReady = ready,
        protectSucceeded = ready,
        dataPlaneReady = dataPlaneReady,
        platformVpnValidated = platformValidated,
        selectedOutboundId = outbound,
    )

    fun connectedRequiresLocalStartupEvidence() {
        check(!snapshot(VpnSessionPhase.CONNECTED, ready = false).provesConnected())
        check(!snapshot(VpnSessionPhase.CONNECTED, ready = true, outbound = "").provesConnected())
        check(!snapshot(VpnSessionPhase.CONNECTED, ready = true, dataPlaneReady = false).provesConnected())
        check(snapshot(VpnSessionPhase.CONNECTED, ready = true, platformValidated = false).provesConnected())
        check(snapshot(VpnSessionPhase.CONNECTED, ready = true).provesConnected())
    }

    fun nonConnectedPhaseCannotPassTheGate() {
        check(!snapshot(VpnSessionPhase.VERIFYING, ready = true).provesConnected())
        check(!snapshot(VpnSessionPhase.STOPPING, ready = true).provesConnected())
    }

    fun selectedOutboundChangeInvalidatesConnectedProof() {
        val before = snapshot(VpnSessionPhase.CONNECTED, ready = true)
        val after = before.copy(selectedOutboundId = "different-opaque")
        check(selectedOutboundRequiresDataPlaneRevalidation(before.generation, before, after))
        check(!selectedOutboundRequiresDataPlaneRevalidation(before.generation, before, before))
        check(
            !selectedOutboundRequiresDataPlaneRevalidation(
                before.generation,
                before.copy(phase = VpnSessionPhase.VERIFYING),
                after,
            ),
        )
    }

    fun healthySelectedOutboundChangeKeepsConnectedProof() {
        check(
            selectedOutboundRevalidationAction(
                ready = true,
                sameNetwork = true,
                expectedSelectedRevision = 1L,
                currentSelectedRevision = 1L,
                expectedSelectedOutboundId = "new-leaf",
                currentSelectedOutboundId = "new-leaf",
            ) == SelectedOutboundRevalidationAction.KEEP_CONNECTED,
        )
    }

    fun failedSelectedOutboundProbeInvalidatesConnectedProof() {
        check(
            selectedOutboundRevalidationAction(
                ready = false,
                sameNetwork = true,
                expectedSelectedRevision = 1L,
                currentSelectedRevision = 1L,
                expectedSelectedOutboundId = "new-leaf",
                currentSelectedOutboundId = "new-leaf",
            ) == SelectedOutboundRevalidationAction.INVALIDATE,
        )
    }

    fun supersededSelectedOutboundProbeRetriesNewestLeaf() {
        check(
            selectedOutboundRevalidationAction(
                ready = true,
                sameNetwork = true,
                expectedSelectedRevision = 1L,
                currentSelectedRevision = 2L,
                expectedSelectedOutboundId = "old-leaf",
                currentSelectedOutboundId = "new-leaf",
            ) == SelectedOutboundRevalidationAction.RETRY_CURRENT,
        )
    }

    fun returnedToSameLeafStillRetriesNewestSelectorRevision() {
        check(
            selectedOutboundRevalidationAction(
                ready = true,
                sameNetwork = true,
                expectedSelectedRevision = 1L,
                currentSelectedRevision = 3L,
                expectedSelectedOutboundId = "same-leaf",
                currentSelectedOutboundId = "same-leaf",
            ) == SelectedOutboundRevalidationAction.RETRY_CURRENT,
        )
    }

    fun commandEndpointReadinessCannotRegressAnOpenedTun() {
        check(phaseAfterCommandEndpointReady(VpnSessionPhase.STARTING_CORE) == VpnSessionPhase.WAITING_TUN)
        check(phaseAfterCommandEndpointReady(VpnSessionPhase.WAITING_TUN) == VpnSessionPhase.WAITING_TUN)
        check(phaseAfterCommandEndpointReady(VpnSessionPhase.VERIFYING) == VpnSessionPhase.VERIFYING)
        check(phaseAfterCommandEndpointReady(VpnSessionPhase.CONNECTED) == VpnSessionPhase.CONNECTED)
    }

    fun duplicateSelectedOutboundDoesNotPublishANewSnapshot() {
        val generation = VpnSessionCoordinator.next("snapshot_duplicate_outbound_test")
        VpnSessionSnapshotCoordinator.begin(generation, "connect")
        val first = VpnSessionSnapshotCoordinator.selectedOutbound(generation, "opaque-test-name", "selector")
        val second = VpnSessionSnapshotCoordinator.selectedOutbound(generation, "opaque-test-name", "selector")
        check(second.sequenceNumber == first.sequenceNumber) {
            "unchanged outbound must not create a new snapshot event"
        }
        check(second.snapshotVersion == first.snapshotVersion) {
            "unchanged outbound must not increment snapshot version"
        }
    }

    fun terminalStopIsTypedCleanAndIdempotent() {
        val generation = VpnSessionCoordinator.next("snapshot_terminal_stop_test")
        VpnSessionSnapshotCoordinator.begin(generation, "connect")
        VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.VERIFYING) {
            it.copy(
                coreReady = true,
                coreStarted = true,
                commandEndpointReady = true,
                tunnelReady = true,
                protectSucceeded = true,
                platformVpnValidated = true,
                selectedOutboundId = "opaque",
            )
        }
        VpnSessionSnapshotCoordinator.requestStop(generation, VpnStopSource.NOTIFICATION)
        val first = VpnSessionSnapshotCoordinator.publishDisconnected(generation, VpnStopSource.NOTIFICATION)
        val second = VpnSessionSnapshotCoordinator.publishDisconnected(generation, VpnStopSource.NOTIFICATION)

        check(first.phase == VpnSessionPhase.DISCONNECTED)
        check(first.requestedAction == "stop")
        check(first.stopSource == VpnStopSource.NOTIFICATION)
        check(first.toEvent()["stopSource"] == "notification")
        check(!first.coreReady && !first.coreStarted && !first.commandEndpointReady)
        check(!first.tunnelReady && !first.protectSucceeded && !first.dataPlaneReady)
        check(!first.platformVpnValidated)
        check(first.selectedOutboundId.isEmpty() && first.selectedOutboundLabel.isEmpty())
        check(second.sequenceNumber == first.sequenceNumber)
        check(second.snapshotVersion == first.snapshotVersion)
    }

    fun repeatedStopPublishesNewestGenerationAndNextStartIsNewer() {
        val firstGeneration = VpnSessionCoordinator.next("snapshot_first_stop_test")
        VpnSessionSnapshotCoordinator.requestStop(firstGeneration, VpnStopSource.FLUTTER)
        val repeatedGeneration = VpnSessionCoordinator.next("snapshot_repeated_stop_test")
        VpnSessionSnapshotCoordinator.requestStop(repeatedGeneration, VpnStopSource.FLUTTER)
        val terminal = VpnSessionSnapshotCoordinator.publishDisconnected(
            repeatedGeneration,
            VpnStopSource.FLUTTER,
        )

        check(terminal.generation == repeatedGeneration)
        val nextStartGeneration = VpnSessionCoordinator.next("snapshot_start_after_repeated_stop_test")
        check(nextStartGeneration > terminal.generation)
    }

    fun lateFirstStopCannotOverrideReconnectAndSecondStop() {
        val initial = VpnSessionCoordinator.next("snapshot_stop_race_initial")
        VpnSessionSnapshotCoordinator.begin(initial, "connect")
        val firstStop = requireNotNull(
            VpnLifecycleIntentCoordinator.reserveStop(
                requestedGeneration = initial,
                preemptive = true,
                reason = "snapshot_stop_race_first",
            ),
        )
        VpnSessionSnapshotCoordinator.requestStop(firstStop, VpnStopSource.FLUTTER)

        val reconnect = VpnSessionCoordinator.next("snapshot_stop_race_reconnect")
        check(VpnLifecycleIntentCoordinator.commitStart(reconnect) { true })
        VpnSessionSnapshotCoordinator.begin(reconnect, "connect")
        val secondStop = requireNotNull(
            VpnLifecycleIntentCoordinator.reserveStop(
                requestedGeneration = reconnect,
                preemptive = true,
                reason = "snapshot_stop_race_second",
            ),
        )
        VpnSessionSnapshotCoordinator.requestStop(secondStop, VpnStopSource.NOTIFICATION)

        val afterLateFirstCompletion = VpnSessionSnapshotCoordinator.publishDisconnected(
            firstStop,
            VpnStopSource.FLUTTER,
        )
        check(afterLateFirstCompletion.generation == secondStop)
        check(afterLateFirstCompletion.phase == VpnSessionPhase.STOP_REQUESTED)
        check(afterLateFirstCompletion.stopSource == VpnStopSource.NOTIFICATION)

        val terminal = VpnSessionSnapshotCoordinator.publishDisconnected(
            secondStop,
            VpnStopSource.NOTIFICATION,
        )
        check(terminal.generation == secondStop)
        check(terminal.phase == VpnSessionPhase.DISCONNECTED)
        check(terminal.stopSource == VpnStopSource.NOTIFICATION)
        check(!CoreProcessOwnerCoordinator.hasOwner())
        check(!TunDescriptorOwner.hasProcessWideOwnership())
    }

    suspend fun alreadyStoppedExternalStopPromotesTheTerminalGeneration() {
        Settings.startedByUser = true
        val generation = VpnSessionCoordinator.next("snapshot_already_stopped_external_stop_test")
        check(BoxService.stop(generation, VpnStopSource.TILE))
        check(!Settings.startedByUser)

        repeat(10) {
            val snapshot = VpnSessionSnapshotCoordinator.current()
            if (snapshot.generation == generation && snapshot.phase == VpnSessionPhase.DISCONNECTED) {
                check(snapshot.stopSource == VpnStopSource.TILE)
                return
            }
            delay(100L)
        }
        error("already-stopped service did not publish a rebased terminal snapshot")
    }

    suspend fun replacementCleanupPreservesExpectedRunningAndPublishesDisconnected() {
        Settings.startedByUser = true
        val generation = VpnSessionCoordinator.next("snapshot_replacement_cleanup")
        VpnSessionSnapshotCoordinator.begin(generation, "connect")
        check(BoxService.stopForReplacement(generation))

        repeat(20) {
            val snapshot = VpnSessionSnapshotCoordinator.current()
            if (snapshot.generation == generation && snapshot.phase == VpnSessionPhase.DISCONNECTED) {
                check(snapshot.stopSource == VpnStopSource.REPLACEMENT)
                check(Settings.startedByUser) {
                    "replacement cleanup cleared the user's expected-running state"
                }
                check(VpnLifecycleIntentCoordinator.acceptsStart(generation))
                check(VpnLifecycleIntentCoordinator.commitStart(generation) { true })
                check(!BoxService.stopForReplacement(generation)) {
                    "late replacement cleanup was accepted after same-generation Start"
                }
                return
            }
            delay(100L)
        }
        error("replacement cleanup did not publish same-generation DISCONNECTED")
    }

    suspend fun repeatedStopAfterFailurePublishesDisconnectedWithoutAReceiver() {
        val failedGeneration = VpnSessionCoordinator.next("snapshot_failed_without_receiver_test")
        VpnSessionSnapshotCoordinator.begin(failedGeneration, "connect")
        VpnSessionSnapshotCoordinator.failure(
            failedGeneration,
            code = "test_start_failure",
            owner = "instrumentation",
            recoverable = true,
        )
        Settings.startedByUser = true
        check(BoxService.stop(source = VpnStopSource.FLUTTER))
        val stopGeneration = VpnSessionCoordinator.current()
        check(stopGeneration > failedGeneration)
        check(!Settings.startedByUser)

        repeat(20) {
            val snapshot = VpnSessionSnapshotCoordinator.current()
            if (
                snapshot.generation == stopGeneration &&
                snapshot.phase == VpnSessionPhase.DISCONNECTED
            ) {
                check(snapshot.stopSource == VpnStopSource.FLUTTER)
                return
            }
            delay(100L)
        }
        error("Stop after FAILED/no-receiver did not publish DISCONNECTED")
    }

}
