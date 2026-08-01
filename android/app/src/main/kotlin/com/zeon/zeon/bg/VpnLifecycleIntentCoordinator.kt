package com.zeon.zeon.bg

/**
 * Serializes Android-owned lifecycle intents that allocate VPN generations.
 *
 * A user Stop is terminal for the generation it supersedes. Internal reloads
 * may not allocate a newer generation until an explicit Connect has already
 * advanced the active session beyond that Stop generation.
 */
object VpnLifecycleIntentCoordinator {
    private data class PendingReload(val ownerToken: Any, val generation: Long)

    data class OwnerDestruction<T>(
        val pendingReloadGeneration: Long?,
        val detachedResource: T,
    )

    private val lock = Any()
    private var pendingReload: PendingReload? = null

    @Volatile
    private var latestStopGeneration = 0L

    fun reserveStop(
        requestedGeneration: Long,
        preemptive: Boolean,
        reason: String,
    ): Long? = synchronized(lock) {
        val current = VpnSessionCoordinator.current()
        val generation = when {
            preemptive -> VpnSessionCoordinator.nextAfter(requestedGeneration, reason)
            requestedGeneration <= 0L -> VpnSessionCoordinator.next(reason)
            requestedGeneration < current -> {
                VpnSessionCoordinator.stale(requestedGeneration, "lifecycle_stop/$reason")
                return@synchronized null
            }
            else -> VpnSessionCoordinator.accept(requestedGeneration, reason)
        }
        latestStopGeneration = maxOf(latestStopGeneration, generation)
        pendingReload = null
        generation
    }

    /**
     * Android may destroy an old Service while a replacement Connect is being
     * accepted. Only the owner that is still current may allocate a destroy
     * Stop; an old owner must never supersede the replacement generation.
     */
    fun reserveDestroyStopIfCurrent(
        expectedGeneration: Long,
        reason: String,
    ): Long? = synchronized(lock) {
        if (expectedGeneration <= 0L || !VpnSessionCoordinator.isCurrent(expectedGeneration)) {
            return@synchronized null
        }
        VpnSessionCoordinator.next(reason).also { generation ->
            latestStopGeneration = maxOf(latestStopGeneration, generation)
            pendingReload = null
        }
    }

    fun reserveReload(
        ownerToken: Any,
        sessionGeneration: Long,
        reloadAllowed: Boolean,
        reason: String,
        ownerAcceptsReload: () -> Boolean = { true },
    ): Long? = synchronized(lock) {
        if (
            !reloadAllowed ||
            !ownerAcceptsReload() ||
            sessionGeneration <= latestStopGeneration ||
            !VpnSessionCoordinator.isCurrent(sessionGeneration)
        ) {
            return@synchronized null
        }
        VpnSessionCoordinator.next(reason).also { generation ->
            pendingReload = PendingReload(ownerToken, generation)
        }
    }

    fun acceptsStart(generation: Long): Boolean = synchronized(lock) {
        generation > latestStopGeneration
    }

    fun commitStart(generation: Long, commit: () -> Boolean): Boolean = synchronized(lock) {
        if (generation <= latestStopGeneration || !VpnSessionCoordinator.isCurrent(generation)) {
            return@synchronized false
        }
        pendingReload = null
        commit()
    }

    /**
     * Commits the replacement owner under the same lock used by Stop.
     * Either the reload owner becomes visible first (and Stop will see it), or
     * the Stop fence wins and the stale reload is never installed.
     */
    fun commitReload(ownerToken: Any, generation: Long, commit: () -> Boolean): Boolean = synchronized(lock) {
        val pending = pendingReload
        if (
            pending?.ownerToken !== ownerToken ||
            pending.generation != generation ||
            generation <= latestStopGeneration ||
            !VpnSessionCoordinator.isCurrent(generation)
        ) {
            if (pending?.ownerToken === ownerToken && pending.generation == generation) {
                pendingReload = null
            }
            return@synchronized false
        }
        val committed = commit()
        pendingReload = null
        committed
    }

    /**
     * Atomically fences an owner against late start/reload commits and detaches
     * the resource which destruction must close. If a commit wins the lock, its
     * resource is detached here; if destruction wins, the commit callback sees
     * the owner's destroyed flag and is rejected.
     */
    fun <T> destroyOwner(ownerToken: Any, detach: () -> T): OwnerDestruction<T> = synchronized(lock) {
        val pending = pendingReload?.takeIf { it.ownerToken === ownerToken }
        if (pending != null) pendingReload = null
        OwnerDestruction(
            pendingReloadGeneration = pending?.generation,
            detachedResource = detach(),
        )
    }

    fun cancelPendingReload(ownerToken: Any): Long? = synchronized(lock) {
        val pending = pendingReload ?: return@synchronized null
        if (pending.ownerToken !== ownerToken) return@synchronized null
        pendingReload = null
        pending.generation
    }

    internal fun latestStopGenerationForTesting(): Long = latestStopGeneration
}
