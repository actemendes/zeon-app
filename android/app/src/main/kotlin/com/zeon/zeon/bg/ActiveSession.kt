package com.zeon.zeon.bg

import com.hiddify.core.libbox.CommandServer
import com.hiddify.core.libbox.PlatformInterface
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Android-side owner for resources whose lifetime must not outlive a VPN generation.
 *
 * Flutter owns its gRPC client objects, while this object owns the native control
 * endpoint, Android platform callbacks, TUN PFD and all Android session jobs.
 */
class ActiveSession(
    val generation: Long,
    val platformInterface: PlatformInterface,
    val tunOwner: TunDescriptorOwner,
) {
    companion object {
        private const val ALREADY_CLOSING_TIMEOUT_MILLIS = 11_500L
        private const val COMMAND_CLIENTS_TIMEOUT_MILLIS = 1_000L
        private const val CORE_TIMEOUT_MILLIS = 8_500L
        private const val SHORT_STEP_TIMEOUT_MILLIS = 500L
    }

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    var commandServer: CommandServer? = null

    private val closing = AtomicBoolean(false)
    private val closed = CompletableDeferred<Unit>()
    private val dataPlaneInvalidated = AtomicBoolean(false)
    private val dataPlaneRevalidationRunning = AtomicBoolean(false)
    private val defaultNetworkRevision = AtomicLong(0L)
    private val selectedOutboundRevision = AtomicLong(0L)

    @Volatile
    private var commandEndpointReady = false

    @Volatile
    private var tunOpened = false

    @Volatile
    private var postTunProtectSucceeded = false

    fun acceptsOperations(): Boolean = !closing.get() && !closed.isCompleted

    fun recordDefaultNetworkChange(): Long = defaultNetworkRevision.incrementAndGet()

    fun currentDefaultNetworkRevision(): Long = defaultNetworkRevision.get()

    fun recordSelectedOutboundChange(): Long = selectedOutboundRevision.incrementAndGet()

    fun currentSelectedOutboundRevision(): Long = selectedOutboundRevision.get()

    fun invalidateDataPlane() {
        dataPlaneInvalidated.set(true)
    }

    fun clearDataPlaneInvalidation() {
        dataPlaneInvalidated.set(false)
    }

    fun needsDataPlaneRevalidation(): Boolean = dataPlaneInvalidated.get()

    fun beginDataPlaneRevalidation(): Boolean =
        dataPlaneRevalidationRunning.compareAndSet(false, true)

    fun finishDataPlaneRevalidation() {
        dataPlaneRevalidationRunning.set(false)
    }

    fun markCommandEndpointReady() {
        commandEndpointReady = true
    }

    fun markTunReady(protectSucceeded: Boolean) {
        tunOpened = true
        postTunProtectSucceeded = protectSucceeded
    }

    internal fun startEvidence(
        permissionGranted: Boolean,
        mobileStartSucceeded: Boolean,
        dataPlaneReady: Boolean = false,
    ) = VpnConnectedGate.Evidence(
        permissionGranted = permissionGranted,
        mobileStartSucceeded = mobileStartSucceeded,
        commandEndpointReady = commandEndpointReady,
        tunOpened = tunOpened && tunOwner.hasOpenDescriptor(generation),
        postTunProtectSucceeded = postTunProtectSucceeded,
        dataPlaneReady = dataPlaneReady,
        generationCurrent = VpnSessionCoordinator.isCurrent(generation),
        sessionAcceptingOperations = acceptsOperations(),
    )

    suspend fun close(
        reason: String,
        closeCommandClientsAndListeners: suspend () -> Unit,
        stopCore: suspend () -> Unit,
        closeCommandServer: suspend (CommandServer?) -> Unit,
        closePlatform: suspend (PlatformInterface) -> Unit,
        clearNetwork: suspend () -> Unit,
    ) {
        if (!closing.compareAndSet(false, true)) {
            val completed = withTimeoutOrNull(ALREADY_CLOSING_TIMEOUT_MILLIS) {
                closed.await()
                true
            } ?: false
            if (!completed) {
                VpnSessionCoordinator.event(
                    "terminal_failure",
                    generation,
                    "phase=session_close resource=existing_close error=timeout",
                    android.util.Log.ERROR,
                )
            }
            return
        }

        withContext(NonCancellable) {
            VpnSessionCoordinator.event(
                "session_close_requested",
                generation,
                "reason=$reason",
            )
            try {
                scope.cancel("VPN session closing: $reason")
                closeStep(
                    "command_clients",
                    COMMAND_CLIENTS_TIMEOUT_MILLIS,
                    closeCommandClientsAndListeners,
                )
                closeStep("core", CORE_TIMEOUT_MILLIS, stopCore)
                closeStep("command_server", SHORT_STEP_TIMEOUT_MILLIS) {
                    val server = commandServer
                    commandServer = null
                    closeCommandServer(server)
                }
                closeStep("platform", SHORT_STEP_TIMEOUT_MILLIS) {
                    closePlatform(platformInterface)
                }
            } finally {
                // TUN and Android network ownership must always be attempted,
                // even if an earlier native/listener step timed out.
                closeStep("tun", SHORT_STEP_TIMEOUT_MILLIS) {
                    tunOwner.close(generation, reason)
                }
                closeStep("network", SHORT_STEP_TIMEOUT_MILLIS, clearNetwork)
                closed.complete(Unit)
                VpnSessionCoordinator.event(
                    "session_close_completed",
                    generation,
                    "reason=$reason",
                )
            }
        }
    }

    private suspend fun closeStep(
        name: String,
        timeoutMillis: Long,
        action: suspend () -> Unit,
    ) {
        val result = SessionCloseDispatcher.runStep(timeoutMillis, action)
        if (result == null) {
            VpnSessionCoordinator.event(
                "terminal_failure",
                generation,
                "phase=session_close resource=$name error=timeout",
                android.util.Log.ERROR,
            )
        } else {
            result.onFailure {
                VpnSessionCoordinator.event(
                    "terminal_failure",
                    generation,
                    "phase=session_close resource=$name error=${it.javaClass.simpleName}",
                    android.util.Log.ERROR,
                )
            }
        }
    }
}
