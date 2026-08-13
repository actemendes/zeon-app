package com.zeon.zeon.bg

/** Prevents VPNService and ProxyService from owning the process-global Go core concurrently. */
object CoreProcessOwnerCoordinator {
    private data class Owner(val token: Any, val generation: Long)

    private val lock = Any()
    private var owner: Owner? = null
    @Volatile
    private var ownershipSettledListener: (() -> Unit)? = null

    fun tryAcquire(token: Any, generation: Long): Boolean = synchronized(lock) {
        val current = owner
        if (current != null && (current.token !== token || current.generation != generation)) {
            return@synchronized false
        }
        owner = Owner(token, generation)
        true
    }

    fun owns(token: Any, generation: Long): Boolean = synchronized(lock) {
        owner?.let { it.token === token && it.generation == generation } == true
    }

    fun release(token: Any, generation: Long): Boolean {
        val released = synchronized(lock) {
            val current = owner ?: return@synchronized true
            if (current.token !== token || current.generation != generation) return@synchronized false
            owner = null
            true
        }
        if (released) ownershipSettledListener?.invoke()
        return released
    }

    fun hasOwner(): Boolean = synchronized(lock) { owner != null }

    fun setOwnershipSettledListener(listener: () -> Unit) {
        ownershipSettledListener = listener
    }

    internal fun generationForTesting(): Long = synchronized(lock) { owner?.generation ?: 0L }
}
