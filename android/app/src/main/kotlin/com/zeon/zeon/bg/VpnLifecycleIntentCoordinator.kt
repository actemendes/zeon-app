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
    private data class ReplacementCleanup(
        val generation: Long,
        val state: ReplacementCleanupState,
    )

    private enum class ReplacementCleanupState {
        PENDING,
        COMPLETED,
        CONSUMED,
    }

    enum class ReplacementStopDecision {
        DISPATCH,
        ALREADY_ACCEPTED,
        REJECTED,
    }

    data class OwnerDestruction<T>(
        val pendingReloadGeneration: Long?,
        val detachedResource: T,
    )

    private val lock = Any()
    private var pendingReload: PendingReload? = null
    private var replacementCleanup: ReplacementCleanup? = null

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
        replacementCleanup = null
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
            replacementCleanup = null
        }
    }

    /**
     * Accepts same-generation cleanup performed immediately before a Start or
     * restart. It closes an old owner but deliberately does not create a
     * terminal Stop fence for the replacement generation.
     */
    fun reserveReplacementStop(generation: Long): ReplacementStopDecision = synchronized(lock) {
        if (
            generation <= latestStopGeneration ||
            !VpnSessionCoordinator.isCurrent(generation)
        ) {
            return@synchronized ReplacementStopDecision.REJECTED
        }
        val current = replacementCleanup
        if (current?.generation == generation) {
            return@synchronized when (current.state) {
                ReplacementCleanupState.PENDING,
                ReplacementCleanupState.COMPLETED -> ReplacementStopDecision.ALREADY_ACCEPTED
                ReplacementCleanupState.CONSUMED -> ReplacementStopDecision.REJECTED
            }
        }
        if (current != null && current.generation > generation) {
            return@synchronized ReplacementStopDecision.REJECTED
        }
        pendingReload = null
        replacementCleanup = ReplacementCleanup(generation, ReplacementCleanupState.PENDING)
        ReplacementStopDecision.DISPATCH
    }

    /** Runs an owner stop only while this cleanup generation is still pending. */
    fun dispatchReplacementStop(generation: Long, stopOwner: () -> Boolean): Boolean = synchronized(lock) {
        val current = replacementCleanup
        if (
            current?.generation != generation ||
            current.state != ReplacementCleanupState.PENDING ||
            generation <= latestStopGeneration ||
            !VpnSessionCoordinator.isCurrent(generation)
        ) {
            return@synchronized false
        }
        stopOwner()
    }

    /**
     * Publishes the replacement terminal snapshot while Start is still fenced,
     * then makes the generation available for its replacement owner. Keeping
     * both operations under this lock prevents a same-generation Start from
     * publishing STARTING before a late DISCONNECTED snapshot.
     */
    fun completeReplacementStop(
        generation: Long,
        publishDisconnected: () -> Unit,
    ): Boolean = synchronized(lock) {
        val current = replacementCleanup
        if (
            current?.generation != generation ||
            generation <= latestStopGeneration ||
            !VpnSessionCoordinator.isCurrent(generation)
        ) {
            return@synchronized false
        }
        when (current.state) {
            ReplacementCleanupState.PENDING -> {
                publishDisconnected()
                replacementCleanup = current.copy(state = ReplacementCleanupState.COMPLETED)
                true
            }
            ReplacementCleanupState.COMPLETED -> true
            ReplacementCleanupState.CONSUMED -> false
        }
    }

    fun replacementStopNeedsFallback(generation: Long): Boolean = synchronized(lock) {
        val current = replacementCleanup
        current?.generation == generation &&
            current.state == ReplacementCleanupState.PENDING &&
            generation > latestStopGeneration &&
            VpnSessionCoordinator.isCurrent(generation)
    }

    /** Executes a timeout publication only if replacement teardown is still pending. */
    fun runIfReplacementStopPending(
        generation: Long,
        action: () -> Unit,
    ): Boolean = synchronized(lock) {
        if (!replacementStopNeedsFallback(generation)) {
            return@synchronized false
        }
        action()
        true
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
            replacementCleanup = null
        }
    }

    fun acceptsStart(generation: Long): Boolean = synchronized(lock) {
        generation > latestStopGeneration &&
            VpnSessionCoordinator.isCurrent(generation) &&
            replacementCleanup?.let {
                it.generation != generation || it.state == ReplacementCleanupState.COMPLETED
            } != false
    }

    fun commitStart(generation: Long, commit: () -> Boolean): Boolean = synchronized(lock) {
        if (generation <= latestStopGeneration || !VpnSessionCoordinator.isCurrent(generation)) {
            return@synchronized false
        }
        val replacement = replacementCleanup
        if (
            replacement?.generation == generation &&
            replacement.state != ReplacementCleanupState.COMPLETED
        ) {
            return@synchronized false
        }
        pendingReload = null
        val committed = commit()
        if (committed) {
            replacementCleanup = if (replacement?.generation == generation) {
                replacement.copy(state = ReplacementCleanupState.CONSUMED)
            } else {
                null
            }
        }
        committed
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
        if (committed) replacementCleanup = null
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
