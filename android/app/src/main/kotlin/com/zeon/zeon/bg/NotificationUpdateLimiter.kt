package com.zeon.zeon.bg

/** Coalesces live traffic samples without scheduling work that could outlive Stop. */
internal class NotificationUpdateLimiter(
    private val intervalMillis: Long = 5_000L,
    private val lock: Any = Any(),
) {
    data class Content(
        val profile: String,
        val outboundId: String,
        val phase: String,
        val text: String,
    ) {
        fun hasSameMeaning(other: Content): Boolean =
            profile == other.profile && outboundId == other.outboundId && phase == other.phase
    }

    init {
        require(intervalMillis > 0L)
    }

    private var generation = 0L
    private var active = false
    private var lastContent: Content? = null
    private var lastPublishedAt: Long? = null

    fun start(ownerGeneration: Long): Boolean = synchronized(lock) {
        if (ownerGeneration <= 0L || ownerGeneration < generation || (!active && ownerGeneration == generation)) {
            return@synchronized false
        }
        generation = ownerGeneration
        active = true
        lastContent = null
        lastPublishedAt = null
        true
    }

    fun close() = synchronized(lock) {
        active = false
        lastContent = null
        lastPublishedAt = null
    }

    /** The owner check, decision and publication share the same lock as close(). */
    fun publish(
        ownerGeneration: Long,
        content: Content,
        nowMillis: Long,
        stillOwnsNotification: () -> Boolean,
        send: () -> Unit,
    ): Boolean = synchronized(lock) {
        if (!active || ownerGeneration != generation || !stillOwnsNotification()) return@synchronized false
        val previous = lastContent
        val meaningChanged = previous == null || !content.hasSameMeaning(previous)
        if (!meaningChanged && content.text == previous?.text) return@synchronized false
        val last = lastPublishedAt
        // A zero clock is valid. Rebase after an unexpected backward clock step
        // instead of suppressing updates until the old timestamp is reached.
        if (!meaningChanged && last != null && nowMillis >= last && nowMillis - last < intervalMillis) {
            return@synchronized false
        }
        send()
        lastContent = content
        lastPublishedAt = nowMillis
        true
    }
}
