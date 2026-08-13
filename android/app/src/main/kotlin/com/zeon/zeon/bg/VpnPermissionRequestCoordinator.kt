package com.zeon.zeon.bg

/**
 * Owns the single Android VPN consent dialog that may be in flight for the
 * process. Permission is global, but its completion belongs to one VPN
 * generation and must never complete a newer Flutter operation by accident.
 */
internal class VpnPermissionRequestCoordinator(
    private val currentGeneration: () -> Long = VpnSessionCoordinator::current,
    private val event: (String, Long, String) -> Unit = { name, generation, details ->
        VpnSessionCoordinator.event(name, generation, details)
    },
) {
    enum class Outcome { Granted, Denied, Stale }

    data class Request(
        val generation: Long,
        val startAfterGrant: Boolean,
        val callback: (Outcome) -> Unit,
    )

    private var pending: Request? = null
    private var dialogGeneration = 0L

    /** Returns true only when the caller must launch the Android dialog. */
    @Synchronized
    fun request(request: Request): Boolean {
        val current = currentGeneration()
        if (request.generation <= 0 || request.generation != current) {
            event(
                "permission_result_ignored_stale",
                request.generation,
                "current_generation=$current session_state=permission source=request reason=stale_request",
            )
            request.callback(Outcome.Stale)
            return false
        }

        val existing = pending
        if (existing != null) {
            if (existing.generation == request.generation) {
                event(
                    "permission_request_started",
                    request.generation,
                    "current_generation=$current session_state=permission source=request reason=duplicate_coalesced",
                )
                val previousCallback = existing.callback
                pending = request.copy(
                    startAfterGrant = existing.startAfterGrant || request.startAfterGrant,
                    callback = { outcome ->
                        previousCallback(outcome)
                        request.callback(outcome)
                    },
                )
                return false
            }

            pending = null
            existing.callback(Outcome.Stale)
            event(
                "permission_result_ignored_stale",
                existing.generation,
                "current_generation=$current session_state=permission source=request reason=superseded",
            )
            // The Android dialog already on screen cannot be replaced. Its
            // result will be treated only as OS consent for this newest attempt.
            pending = request
            return false
        }

        pending = request
        dialogGeneration = request.generation
        event(
            "permission_request_started",
            request.generation,
            "current_generation=$current session_state=permission source=request reason=dialog_launch",
        )
        return true
    }

    @Synchronized
    fun complete(granted: Boolean): Request? {
        val request = pending
        val ownerGeneration = dialogGeneration
        dialogGeneration = 0L
        pending = null
        val current = currentGeneration()

        if (request == null) {
            event(
                "permission_result_ignored_stale",
                ownerGeneration,
                "current_generation=$current session_state=permission source=result reason=duplicate_or_cancelled",
            )
            return null
        }

        if (request.generation != current) {
            event(
                "permission_result_ignored_stale",
                request.generation,
                "current_generation=$current session_state=permission source=result reason=generation_changed",
            )
            request.callback(Outcome.Stale)
            return null
        }

        event(
            "permission_result_received",
            request.generation,
            "current_generation=$current session_state=permission source=result reason=${if (granted) "granted" else "denied"}",
        )
        request.callback(if (granted) Outcome.Granted else Outcome.Denied)
        return request
    }

    @Synchronized
    fun completeAlreadyGranted(generation: Long, callback: (Outcome) -> Unit) {
        val current = currentGeneration()
        if (generation != current) {
            event(
                "permission_result_ignored_stale",
                generation,
                "current_generation=$current session_state=permission source=prepare reason=already_granted_but_stale",
            )
            callback(Outcome.Stale)
            return
        }
        event(
            "permission_result_received",
            generation,
            "current_generation=$current session_state=permission source=prepare reason=already_granted",
        )
        callback(Outcome.Granted)
    }
}
