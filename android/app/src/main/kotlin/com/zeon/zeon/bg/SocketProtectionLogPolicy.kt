package com.zeon.zeon.bg

/** Counts successful socket protection without logging every core socket. */
internal class SocketProtectionLogPolicy(private val intervalMillis: Long = 30_000L) {
    data class Emission(val success: Boolean, val count: Long, val windowMillis: Long, val initial: Boolean)

    init {
        require(intervalMillis > 0L)
    }

    private var generation = 0L
    private var windowStartedAt = 0L
    private var pendingSuccesses = 0L

    @Synchronized
    fun record(
        ownerGeneration: Long,
        currentGeneration: Long,
        success: Boolean,
        nowMillis: Long,
    ): Emission? {
        // Every failure, including a stale owner's failure, remains observable.
        // It must not reset or consume another owner's successful-socket count.
        if (!success) return Emission(false, 1L, 0L, false)
        if (ownerGeneration <= 0L || ownerGeneration != currentGeneration || ownerGeneration < generation) return null
        if (ownerGeneration > generation) {
            generation = ownerGeneration
            windowStartedAt = nowMillis
            pendingSuccesses = 0L
            return Emission(true, 1L, 0L, true)
        }
        pendingSuccesses++
        val elapsed = if (nowMillis < windowStartedAt) 0L else nowMillis - windowStartedAt
        if (nowMillis >= windowStartedAt && elapsed < intervalMillis) return null
        val emission = Emission(true, pendingSuccesses, elapsed, false)
        pendingSuccesses = 0L
        windowStartedAt = nowMillis
        return emission
    }
}
