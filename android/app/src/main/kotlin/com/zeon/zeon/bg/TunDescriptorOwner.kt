package com.zeon.zeon.bg

import android.os.ParcelFileDescriptor
import android.util.Log
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the Android side of the TUN descriptor for exactly one VPN generation.
 *
 * libbox duplicates this descriptor before constructing sing-tun. That duplicate
 * does not transfer ownership of this ParcelFileDescriptor back to Go.
 */
class TunDescriptorOwner {
    private data class OwnedDescriptor(
        val generation: Long,
        val identity: String,
        val descriptor: ParcelFileDescriptor,
    )

    private val lock = Any()
    private val identities = AtomicLong(0)
    private var owned: OwnedDescriptor? = null
    private var lastOpenedGeneration = 0L

    fun open(
        generation: Long,
        descriptor: ParcelFileDescriptor,
        validate: () -> Unit = {},
    ): Int {
        try {
            validate()
        } catch (error: Throwable) {
            descriptor.closeQuietly()
            VpnSessionCoordinator.event(
                "tun_close",
                generation,
                "identity=pending reason=post_establish_validation_failure error=${error.javaClass.simpleName}",
                Log.ERROR,
            )
            throw error
        }

        synchronized(lock) {
            if (!VpnSessionCoordinator.isCurrent(generation)) {
                descriptor.closeQuietly()
                VpnSessionCoordinator.stale(generation, "tun_open")
                error("stale VPN session attempted to open TUN")
            }
            if (owned != null || lastOpenedGeneration == generation) {
                descriptor.closeQuietly()
                VpnSessionCoordinator.event(
                    "tun_open_rejected_duplicate",
                    generation,
                    "identity=pending",
                    Log.ERROR,
                )
                error("VPN session generation already opened a TUN descriptor")
            }

            val identity = "tun-${identities.incrementAndGet()}"
            owned = OwnedDescriptor(generation, identity, descriptor)
            lastOpenedGeneration = generation
            VpnSessionCoordinator.event("tun_open_success", generation, "identity=$identity")
            return descriptor.fd
        }
    }

    fun close(generation: Long, reason: String): Boolean {
        val closing = synchronized(lock) {
            val current = owned ?: return false
            if (current.generation != generation) {
                VpnSessionCoordinator.stale(generation, "tun_close/$reason")
                return false
            }
            owned = null
            current
        }
        closing.descriptor.closeQuietly()
        VpnSessionCoordinator.event(
            "tun_close",
            generation,
            "identity=${closing.identity} reason=$reason",
        )
        return true
    }

    fun hasOpenDescriptor(generation: Long): Boolean = synchronized(lock) {
        owned?.generation == generation
    }

    private fun ParcelFileDescriptor.closeQuietly() {
        runCatching { close() }
            .onFailure {
                VpnSessionCoordinator.event(
                    "tun_close",
                    VpnSessionCoordinator.current(),
                    "identity=opaque error=${it.javaClass.simpleName}",
                    Log.ERROR,
                )
            }
    }
}
