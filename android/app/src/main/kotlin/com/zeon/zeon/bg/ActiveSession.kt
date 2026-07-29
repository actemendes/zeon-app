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
import java.util.concurrent.atomic.AtomicBoolean

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
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    var commandServer: CommandServer? = null

    private val closing = AtomicBoolean(false)
    private val closed = CompletableDeferred<Unit>()

    @Volatile
    private var commandEndpointReady = false

    @Volatile
    private var tunOpened = false

    @Volatile
    private var postTunProtectSucceeded = false

    fun acceptsOperations(): Boolean = !closing.get() && !closed.isCompleted

    fun markCommandEndpointReady() {
        commandEndpointReady = true
    }

    fun markTunReady(protectSucceeded: Boolean) {
        tunOpened = true
        postTunProtectSucceeded = protectSucceeded
    }

    internal fun startEvidence(permissionGranted: Boolean, mobileStartSucceeded: Boolean) = VpnConnectedGate.Evidence(
        permissionGranted = permissionGranted,
        mobileStartSucceeded = mobileStartSucceeded,
        commandEndpointReady = commandEndpointReady,
        tunOpened = tunOpened && tunOwner.hasOpenDescriptor(generation),
        postTunProtectSucceeded = postTunProtectSucceeded,
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
            closed.await()
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
                closeStep("command_clients", closeCommandClientsAndListeners)
                closeStep("core", stopCore)
                closeStep("command_server") {
                    val server = commandServer
                    commandServer = null
                    closeCommandServer(server)
                }
                closeStep("platform") { closePlatform(platformInterface) }
                closeStep("tun") { tunOwner.close(generation, reason) }
                closeStep("network") { clearNetwork() }
            } finally {
                closed.complete(Unit)
                VpnSessionCoordinator.event(
                    "session_close_completed",
                    generation,
                    "reason=$reason",
                )
            }
        }
    }

    private suspend fun closeStep(name: String, action: suspend () -> Unit) {
        runCatching { action() }
            .onFailure {
                VpnSessionCoordinator.event(
                    "terminal_failure",
                    generation,
                    "phase=session_close resource=$name error=${it.javaClass.simpleName}",
                    android.util.Log.ERROR,
                )
            }
    }
}
