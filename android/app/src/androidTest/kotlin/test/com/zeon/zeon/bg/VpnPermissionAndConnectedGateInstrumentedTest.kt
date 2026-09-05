package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.VpnConnectedGate
import com.zeon.zeon.bg.VpnDataPlaneProbe
import com.zeon.zeon.bg.VpnDataPlaneTargetResult
import com.zeon.zeon.bg.VpnPermissionRequestCoordinator
import com.zeon.zeon.bg.StartupDataPlaneProbeAction
import com.zeon.zeon.bg.startupDataPlaneProbeAction
import com.zeon.zeon.bg.startupDataPlaneProofReady
import com.zeon.zeon.bg.parsePendingOutboundSelection
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class VpnPermissionAndConnectedGateInstrumentedTest {
    private class Harness(seed: Long = 100L) {
        var current = seed
        val events = mutableListOf<String>()
        val outcomes = mutableListOf<VpnPermissionRequestCoordinator.Outcome>()
        val gate = VpnPermissionRequestCoordinator(
            currentGeneration = { current },
            event = { name, generation, _ -> events += "$name/$generation" },
        )

        fun request(generation: Long = current, startAfterGrant: Boolean = false): Boolean = gate.request(
            VpnPermissionRequestCoordinator.Request(generation, startAfterGrant) { outcomes += it },
        )
    }

    fun firstConnectPermissionGrantedCompletesCurrentAttempt() {
        val h = Harness()
        check(h.request())
        check(h.gate.complete(true)?.generation == h.current)
        check(h.outcomes == listOf(VpnPermissionRequestCoordinator.Outcome.Granted))
    }

    fun permissionDeniedDoesNotBecomeGranted() {
        val h = Harness()
        h.request()
        h.gate.complete(false)
        check(h.outcomes == listOf(VpnPermissionRequestCoordinator.Outcome.Denied))
    }

    fun closedDialogIsDenied() = permissionDeniedDoesNotBecomeGranted()

    fun delayedPermissionUsesBarrierAndKeepsGeneration() {
        val h = Harness()
        val requested = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val worker = Thread {
            check(h.request())
            requested.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            h.gate.complete(true)
            completed.countDown()
        }
        worker.start()
        check(requested.await(2, TimeUnit.SECONDS))
        check(h.outcomes.isEmpty())
        release.countDown()
        check(completed.await(2, TimeUnit.SECONDS))
        worker.join()
        check(h.outcomes.single() == VpnPermissionRequestCoordinator.Outcome.Granted)
    }

    fun stopWhilePermissionPendingMakesResultStale() {
        val h = Harness()
        h.request()
        h.current++
        check(h.gate.complete(true) == null)
        check(h.outcomes.single() == VpnPermissionRequestCoordinator.Outcome.Stale)
    }

    fun restartWhilePermissionPendingMakesOldResultStale() = stopWhilePermissionPendingMakesResultStale()

    fun duplicatePermissionCallbackCompletesOnlyOnce() {
        val h = Harness()
        h.request()
        h.gate.complete(true)
        h.gate.complete(true)
        check(h.outcomes.size == 1)
        check(h.events.count { it.startsWith("permission_result_ignored_stale") } == 1)
    }

    fun stalePermissionResultCannotCompleteNewGeneration() {
        val h = Harness()
        h.request()
        h.current++
        h.gate.complete(true)
        check(h.outcomes.single() == VpnPermissionRequestCoordinator.Outcome.Stale)
    }

    fun commandEndpointWithoutTunCannotPublishStarted() {
        val result = VpnConnectedGate.evaluate(readyEvidence().copy(tunOpened = false))
        check(result is VpnConnectedGate.Result.Rejected && "tun" in result.missing)
    }

    fun tunWithoutMobileStartCannotPublishStarted() {
        val result = VpnConnectedGate.evaluate(readyEvidence().copy(mobileStartSucceeded = false))
        check(result is VpnConnectedGate.Result.Rejected && "mobile_start" in result.missing)
    }

    fun oldGenerationCoreSuccessCannotPublishStarted() {
        val result = VpnConnectedGate.evaluate(readyEvidence().copy(generationCurrent = false))
        check(result is VpnConnectedGate.Result.Rejected && "generation" in result.missing)
    }

    fun missingDataPlaneProofCannotPublishStarted() {
        val result = VpnConnectedGate.evaluate(readyEvidence().copy(dataPlaneReady = false))
        check(result is VpnConnectedGate.Result.Rejected && "data_plane" in result.missing)
    }

    fun oneRealHttpsTargetProvesDataPlane() {
        val results = listOf(
            VpnDataPlaneTargetResult("zeon_204", ready = false, failureCategory = "timeout"),
            VpnDataPlaneTargetResult("gstatic_204", ready = true),
            VpnDataPlaneTargetResult("cloudflare_byte", ready = false, failureCategory = "dns"),
        )
        check(VpnDataPlaneProbe.hasReadyTarget(results))
        check(startupDataPlaneProofReady(true, "leaf-a", "leaf-a"))
        check(!startupDataPlaneProofReady(true, "leaf-a", "leaf-b"))
    }

    fun noRealHttpsTargetCannotProveDataPlane() {
        val results = listOf(
            VpnDataPlaneTargetResult("zeon_204", ready = false, failureCategory = "dns"),
            VpnDataPlaneTargetResult("gstatic_204", ready = false, failureCategory = "timeout"),
            VpnDataPlaneTargetResult("cloudflare_byte", ready = false, failureCategory = "connect"),
        )
        check(!VpnDataPlaneProbe.hasReadyTarget(results))
        check(!startupDataPlaneProofReady(false, "leaf-a", "leaf-a"))
    }

    fun stableTransientVpnDnsFailureGetsBoundedRetry() {
        check(
            startupDataPlaneProbeAction(
                proofReady = false,
                selectedBeforeProbe = "leaf-a",
                selectedAfterProbe = "leaf-a",
                failureCategories = listOf("dns", "dns", "dns"),
                attempt = 1,
                maxAttempts = 3,
            ) == StartupDataPlaneProbeAction.RETRY_TRANSIENT_VPN_NETWORK,
        )
    }

    fun transientVpnDnsRetryNeverAuthorizesConnectedAndRemainsBounded() {
        check(
            startupDataPlaneProbeAction(
                proofReady = false,
                selectedBeforeProbe = "leaf-a",
                selectedAfterProbe = "leaf-a",
                failureCategories = listOf("dns", "dns_empty", "vpn_network_missing"),
                attempt = 3,
                maxAttempts = 3,
            ) == StartupDataPlaneProbeAction.COMPLETE,
        )
        check(!startupDataPlaneProofReady(false, "leaf-a", "leaf-a"))
    }

    fun stableNonTransientDataPlaneFailureIsNotRetried() {
        check(
            startupDataPlaneProbeAction(
                proofReady = false,
                selectedBeforeProbe = "leaf-a",
                selectedAfterProbe = "leaf-a",
                failureCategories = listOf("timeout", "connect", "tls"),
                attempt = 1,
                maxAttempts = 3,
            ) == StartupDataPlaneProbeAction.COMPLETE,
        )
    }

    fun changedAutoselectLeafStillRequiresFreshProof() {
        check(
            startupDataPlaneProbeAction(
                proofReady = false,
                selectedBeforeProbe = "leaf-a",
                selectedAfterProbe = "leaf-b",
                failureCategories = listOf("timeout"),
                attempt = 1,
                maxAttempts = 3,
            ) == StartupDataPlaneProbeAction.RETRY_SELECTED_OUTBOUND,
        )
    }

    fun pendingSelectionGetsOneFreshProofWithoutAuthorizingConnected() {
        check(
            startupDataPlaneProbeAction(
                proofReady = false,
                selectedBeforeProbe = "balance",
                selectedAfterProbe = "balance",
                failureCategories = listOf("timeout", "dns", "dns"),
                attempt = 1,
                maxAttempts = 4,
                pendingSelectionApplied = true,
            ) == StartupDataPlaneProbeAction.RETRY_PENDING_SELECTION,
        )
        check(
            startupDataPlaneProbeAction(
                proofReady = false,
                selectedBeforeProbe = "balance",
                selectedAfterProbe = "balance",
                failureCategories = listOf("timeout", "dns", "dns"),
                attempt = 2,
                maxAttempts = 4,
                pendingSelectionApplied = true,
            ) == StartupDataPlaneProbeAction.COMPLETE,
        )
        check(!startupDataPlaneProofReady(false, "balance", "balance"))
    }

    fun pendingOutboundSelectionAcceptsOnlyBoundedValidTags() {
        val parsed = parsePendingOutboundSelection(
            """{"group_tag":"select","outbound_tag":"balance"}""",
        )
        check(parsed?.groupTag == "select")
        check(parsed?.outboundTag == "balance")
        check(parsePendingOutboundSelection("""{"group_tag":"","outbound_tag":"balance"}""") == null)
        check(parsePendingOutboundSelection("""{"group_tag":"select","outbound_tag":"bad\nvalue"}""") == null)
        check(parsePendingOutboundSelection("not-json") == null)
        check(
            parsePendingOutboundSelection(
                """{"group_tag":"select","outbound_tag":"${"x".repeat(513)}"}""",
            ) == null,
        )
    }

    fun reconnectAfterPermissionFailureNeedsNoProcessRestart() {
        val h = Harness()
        h.request()
        h.gate.complete(false)
        h.current++
        check(h.request(h.current))
        h.gate.complete(true)
        check(
            h.outcomes == listOf(
                VpnPermissionRequestCoordinator.Outcome.Denied,
                VpnPermissionRequestCoordinator.Outcome.Granted,
            ),
        )
    }

    private fun readyEvidence() = VpnConnectedGate.Evidence(
        permissionGranted = true,
        mobileStartSucceeded = true,
        commandEndpointReady = true,
        tunOpened = true,
        postTunProtectSucceeded = true,
        dataPlaneReady = true,
        generationCurrent = true,
        sessionAcceptingOperations = true,
    )
}
