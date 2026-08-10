package test.com.zeon.zeon.bg

import android.os.ParcelFileDescriptor
import com.hiddify.core.libbox.PlatformInterface
import com.hiddify.core.libbox.TunOptions
import com.zeon.zeon.bg.GenerationBoundPlatformInterface
import com.zeon.zeon.bg.TunCallbackDisposition
import com.zeon.zeon.bg.TunCallbackOwnership
import com.zeon.zeon.bg.TunCallbackRejectionReason
import com.zeon.zeon.bg.TunDescriptorOwner
import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.bg.VpnSessionPhase
import com.zeon.zeon.bg.VpnSessionSnapshotCoordinator
import java.lang.reflect.Proxy

class TunCallbackOwnershipInstrumentedTest {
    fun matchingAcceptingGenerationCanOpenTun() {
        val generation = VpnSessionCoordinator.next("tun_callback_matching")
        val decision = TunCallbackOwnership.classify(
            ownerGeneration = generation,
            currentGeneration = generation,
            activeSessionGeneration = generation,
            activeSessionAccepting = true,
        )
        check(decision.disposition == TunCallbackDisposition.ACCEPT)

        val owner = TunDescriptorOwner()
        val descriptor = descriptor()
        owner.open(generation, descriptor)
        check(owner.hasOpenDescriptor(generation))
        check(owner.close(generation, "matching_callback_test"))
    }

    fun oldGenerationMismatchIsStaleAndClosesDescriptor() {
        val oldGeneration = VpnSessionCoordinator.next("tun_callback_old")
        val activeGeneration = VpnSessionCoordinator.next("tun_callback_replacement")
        val rejected = descriptor()
        val decision = TunCallbackOwnership.classifyAndCloseRejected(
            ownerGeneration = oldGeneration,
            currentGeneration = activeGeneration,
            activeSessionGeneration = activeGeneration,
            activeSessionAccepting = true,
            closeRejectedDescriptor = rejected::close,
        )

        check(decision.disposition == TunCallbackDisposition.STALE_CALLBACK)
        check(decision.rejectionReason == TunCallbackRejectionReason.OWNER_GENERATION_MISMATCH)
        check(!decision.reportIncident)
        check(!rejected.fileDescriptor.valid())
    }

    fun currentGenerationNotAcceptingRemainsIncident() {
        val generation = VpnSessionCoordinator.next("tun_callback_not_accepting")
        val rejected = descriptor()
        val decision = TunCallbackOwnership.classifyAndCloseRejected(
            ownerGeneration = generation,
            currentGeneration = generation,
            activeSessionGeneration = generation,
            activeSessionAccepting = false,
            closeRejectedDescriptor = rejected::close,
        )

        check(decision.disposition == TunCallbackDisposition.CURRENT_GENERATION_TUN_FAILURE)
        check(decision.rejectionReason == TunCallbackRejectionReason.SESSION_NOT_ACCEPTING)
        check(decision.reportIncident)
        check(!rejected.fileDescriptor.valid())
    }

    fun missingCurrentSessionWhileWaitingForTunRemainsIncident() {
        val generation = VpnSessionCoordinator.next("tun_callback_missing_session")
        VpnSessionSnapshotCoordinator.begin(generation, "connect")
        VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.WAITING_TUN)
        check(VpnSessionSnapshotCoordinator.current().phase == VpnSessionPhase.WAITING_TUN)

        val decision = TunCallbackOwnership.classify(
            ownerGeneration = generation,
            currentGeneration = generation,
            activeSessionGeneration = null,
            activeSessionAccepting = false,
        )
        check(decision.disposition == TunCallbackDisposition.CURRENT_GENERATION_TUN_FAILURE)
        check(decision.rejectionReason == TunCallbackRejectionReason.NO_ACTIVE_SESSION)
        check(decision.reportIncident)
    }

    fun staleCallbackCannotReplaceNewGenerationDescriptor() {
        val oldGeneration = VpnSessionCoordinator.next("tun_callback_old_owner")
        val newGeneration = VpnSessionCoordinator.next("tun_callback_new_owner")
        val owner = TunDescriptorOwner()
        val currentDescriptor = descriptor()
        owner.open(newGeneration, currentDescriptor)

        val rejected = descriptor()
        val decision = TunCallbackOwnership.classifyAndCloseRejected(
            ownerGeneration = oldGeneration,
            currentGeneration = newGeneration,
            activeSessionGeneration = newGeneration,
            activeSessionAccepting = true,
            closeRejectedDescriptor = rejected::close,
        )
        check(decision.disposition == TunCallbackDisposition.STALE_CALLBACK)
        check(!rejected.fileDescriptor.valid())
        check(owner.hasOpenDescriptor(newGeneration))
        check(currentDescriptor.fileDescriptor.valid())
        check(owner.close(newGeneration, "stale_callback_test"))
    }

    fun oldCallbackIsStaleEvenBeforeOldSessionDetaches() {
        val oldGeneration = VpnSessionCoordinator.next("tun_callback_attached_old")
        val newGeneration = VpnSessionCoordinator.next("tun_callback_reserved_new")
        val rejected = descriptor()
        val decision = TunCallbackOwnership.classifyAndCloseRejected(
            ownerGeneration = oldGeneration,
            currentGeneration = newGeneration,
            activeSessionGeneration = oldGeneration,
            activeSessionAccepting = true,
            closeRejectedDescriptor = rejected::close,
        )

        check(decision.disposition == TunCallbackDisposition.STALE_CALLBACK)
        check(decision.rejectionReason == TunCallbackRejectionReason.OWNER_GENERATION_MISMATCH)
        check(!rejected.fileDescriptor.valid())
    }

    fun rapidReplacementDoesNotChangeCallbackOwnerGeneration() {
        val oldGeneration = VpnSessionCoordinator.next("tun_bound_interface_old")
        var observedGeneration = 0L
        val bound = GenerationBoundPlatformInterface(
            ownerGeneration = oldGeneration,
            delegate = platform(),
            openTunForOwner = { generation, _ ->
                observedGeneration = generation
                37
            },
            controlSocketForOwner = { _, _ -> },
        )

        val newGeneration = VpnSessionCoordinator.next("tun_bound_interface_new")
        check(newGeneration > oldGeneration)
        check(bound.ownerGeneration == oldGeneration)
        check(bound.openTun(tunOptions()) == 37)
        check(observedGeneration == oldGeneration)
    }

    private fun platform(): PlatformInterface =
        Proxy.newProxyInstance(
            PlatformInterface::class.java.classLoader,
            arrayOf(PlatformInterface::class.java),
        ) { _, method, _ ->
            when (method.returnType) {
                java.lang.Boolean.TYPE -> false
                java.lang.Integer.TYPE -> 0
                java.lang.Long.TYPE -> 0L
                else -> null
            }
        } as PlatformInterface

    private fun tunOptions(): TunOptions =
        Proxy.newProxyInstance(
            TunOptions::class.java.classLoader,
            arrayOf(TunOptions::class.java),
        ) { _, method, _ ->
            when (method.returnType) {
                java.lang.Boolean.TYPE -> false
                java.lang.Integer.TYPE -> 0
                java.lang.Long.TYPE -> 0L
                else -> null
            }
        } as TunOptions

    private fun descriptor(): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        pipe[1].close()
        return pipe[0]
    }
}
