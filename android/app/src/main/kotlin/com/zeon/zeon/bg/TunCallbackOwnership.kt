package com.zeon.zeon.bg

enum class TunCallbackRejectionReason {
    NO_ACTIVE_SESSION,
    OWNER_GENERATION_MISMATCH,
    SESSION_NOT_ACCEPTING,
}

enum class TunCallbackDisposition {
    ACCEPT,
    STALE_CALLBACK,
    CURRENT_GENERATION_TUN_FAILURE,
}

data class TunCallbackDecision(
    val disposition: TunCallbackDisposition,
    val rejectionReason: TunCallbackRejectionReason? = null,
) {
    val accepted: Boolean
        get() = disposition == TunCallbackDisposition.ACCEPT

    val reportIncident: Boolean
        get() = disposition == TunCallbackDisposition.CURRENT_GENERATION_TUN_FAILURE
}

/**
 * Classifies a TUN callback using the immutable generation captured by the
 * platform interface that owns the native core callback.
 */
object TunCallbackOwnership {
    fun classify(
        ownerGeneration: Long,
        currentGeneration: Long,
        activeSessionGeneration: Long?,
        activeSessionAccepting: Boolean,
    ): TunCallbackDecision {
        if (ownerGeneration != currentGeneration) {
            return TunCallbackDecision(
                TunCallbackDisposition.STALE_CALLBACK,
                TunCallbackRejectionReason.OWNER_GENERATION_MISMATCH,
            )
        }
        val reason = when {
            activeSessionGeneration == null -> TunCallbackRejectionReason.NO_ACTIVE_SESSION
            activeSessionGeneration != ownerGeneration -> TunCallbackRejectionReason.OWNER_GENERATION_MISMATCH
            !activeSessionAccepting -> TunCallbackRejectionReason.SESSION_NOT_ACCEPTING
            else -> return TunCallbackDecision(TunCallbackDisposition.ACCEPT)
        }
        return TunCallbackDecision(TunCallbackDisposition.CURRENT_GENERATION_TUN_FAILURE, reason)
    }

    fun classifyAndCloseRejected(
        ownerGeneration: Long,
        currentGeneration: Long,
        activeSessionGeneration: Long?,
        activeSessionAccepting: Boolean,
        closeRejectedDescriptor: () -> Unit,
    ): TunCallbackDecision {
        val decision = classify(
            ownerGeneration = ownerGeneration,
            currentGeneration = currentGeneration,
            activeSessionGeneration = activeSessionGeneration,
            activeSessionAccepting = activeSessionAccepting,
        )
        if (!decision.accepted) closeRejectedDescriptor()
        return decision
    }
}
