package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.CoreStartupGate
import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.bg.ownsCurrentStartupFailure

class CoreStartupGateInstrumentedTest {
    suspend fun mobileStartSuccessRequiresEndpointReadiness() {
        val generation = VpnSessionCoordinator.next("startup_success")
        var started = false

        val result = CoreStartupGate.awaitReady(
            generation = generation,
            startCore = { started = true },
            endpointReady = { started },
            delayMillis = 0,
        )

        check(CoreStartupGate.Result.Ready == result)
    }

    suspend fun mobileStartExceptionFailsStartup() {
        val generation = VpnSessionCoordinator.next("startup_exception")

        val result = CoreStartupGate.awaitReady(
            generation = generation,
            startCore = { error("boom") },
            endpointReady = { true },
            delayMillis = 0,
        )

        check(result is CoreStartupGate.Result.Failed)
    }

    suspend fun endpointTimeoutDoesNotBecomeReady() {
        val generation = VpnSessionCoordinator.next("startup_timeout")

        val result = CoreStartupGate.awaitReady(
            generation = generation,
            startCore = null,
            endpointReady = { false },
            maxAttempts = 2,
            delayMillis = 0,
        )

        check(CoreStartupGate.Result.Timeout == result)
    }

    suspend fun stopDuringStartSupersedesPendingResult() {
        val generation = VpnSessionCoordinator.next("startup_then_stop")

        val result = CoreStartupGate.awaitReady(
            generation = generation,
            startCore = null,
            endpointReady = {
                VpnSessionCoordinator.next("stop_during_start")
                false
            },
            maxAttempts = 2,
            delayMillis = 0,
        )

        check(CoreStartupGate.Result.Superseded == result)
    }

    suspend fun restartDuringStartSupersedesPendingResult() {
        val generation = VpnSessionCoordinator.next("startup_then_restart")

        val result = CoreStartupGate.awaitReady(
            generation = generation,
            startCore = { VpnSessionCoordinator.next("restart_during_start") },
            endpointReady = { true },
            delayMillis = 0,
        )

        check(CoreStartupGate.Result.Superseded == result)
    }

    fun onlyTheCurrentAcceptingSessionReportsAStartFailure() {
        check(
            ownsCurrentStartupFailure(
                generation = 42L,
                currentGeneration = 42L,
                activeSessionGeneration = 42L,
                activeSessionAccepting = true,
            ),
        )
        check(
            !ownsCurrentStartupFailure(
                generation = 41L,
                currentGeneration = 42L,
                activeSessionGeneration = 42L,
                activeSessionAccepting = true,
            ),
        )
        check(
            !ownsCurrentStartupFailure(
                generation = 42L,
                currentGeneration = 42L,
                activeSessionGeneration = 42L,
                activeSessionAccepting = false,
            ),
        )
    }
}
