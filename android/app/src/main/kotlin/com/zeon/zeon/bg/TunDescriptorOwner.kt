package com.zeon.zeon.bg

import android.os.ParcelFileDescriptor
import android.util.Log
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the Android side of the TUN descriptor for exactly one VPN generation.
 *
 * libbox duplicates this descriptor before constructing sing-tun. That duplicate
 * does not transfer ownership of this ParcelFileDescriptor back to Go.
 */
class TunDescriptorOwner {
    companion object {
        private val processIdentities = AtomicLong(0L)
        private val processOwnershipLock = Any()
        private val processOwnedIdentities = ConcurrentHashMap.newKeySet<String>()

        @Volatile
        private var ownershipSettledListener: (() -> Unit)? = null

        fun hasProcessWideOwnership(): Boolean = processOwnedIdentities.isNotEmpty()

        suspend fun awaitProcessSettled(timeoutMillis: Long = 3_000L): Boolean =
            withTimeoutOrNull(timeoutMillis) {
                while (hasProcessWideOwnership()) delay(25L)
                true
            } ?: false

        fun setOwnershipSettledListener(listener: () -> Unit) {
            ownershipSettledListener = listener
        }
    }

    private data class OwnedDescriptor(
        val generation: Long,
        val identity: String,
        val descriptor: ParcelFileDescriptor,
    )

    private val lock = Any()
    private var owned: OwnedDescriptor? = null
    private var closingGeneration = 0L
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
            if (owned != null || closingGeneration != 0L || lastOpenedGeneration == generation) {
                descriptor.closeQuietly()
                VpnSessionCoordinator.event(
                    "tun_open_rejected_duplicate",
                    generation,
                    "identity=pending",
                    Log.ERROR,
                )
                error("VPN session generation already opened a TUN descriptor")
            }

            val identity = synchronized(processOwnershipLock) {
                if (processOwnedIdentities.isNotEmpty()) {
                    descriptor.closeQuietly()
                    VpnSessionCoordinator.event(
                        "tun_open_rejected_process_owner",
                        generation,
                        "identity=pending",
                        Log.ERROR,
                    )
                    error("another process-wide TUN owner is still active")
                }
                "tun-${processIdentities.incrementAndGet()}".also(processOwnedIdentities::add)
            }
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
            closingGeneration = generation
            current
        }
        try {
            closing.descriptor.closeQuietly()
            VpnSessionCoordinator.event(
                "tun_close",
                generation,
                "identity=${closing.identity} reason=$reason",
            )
        } finally {
            synchronized(lock) {
                if (closingGeneration == generation) closingGeneration = 0L
            }
            synchronized(processOwnershipLock) {
                processOwnedIdentities.remove(closing.identity)
            }
            ownershipSettledListener?.invoke()
        }
        return true
    }

    fun hasOpenDescriptor(generation: Long): Boolean = synchronized(lock) {
        owned?.generation == generation
    }

    fun hasOwnership(): Boolean = synchronized(lock) {
        owned != null || closingGeneration != 0L
    }

    suspend fun awaitSettled(timeoutMillis: Long = 3_000L): Boolean =
        withTimeoutOrNull(timeoutMillis) {
            while (hasOwnership()) delay(25L)
            true
        } ?: false

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
