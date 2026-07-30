package com.zeon.zeon.bg

/**
 * Serializes the Android notification and VPN consent dialogs for one VPN
 * operation. A dialog result belongs to the generation that launched it; when
 * a newer operation supersedes that generation, the result is used only to
 * re-evaluate the OS permission state for the queued current operation.
 */
internal class StartPermissionRequestCoordinator(
    private val currentGeneration: () -> Long = VpnSessionCoordinator::current,
    private val event: (String, Long, String) -> Unit = { name, generation, details ->
        VpnSessionCoordinator.event(name, generation, details)
    },
) {
    enum class Outcome {
        Granted,
        NotificationDenied,
        VpnDenied,
        Stale,
    }

    enum class Action {
        None,
        RequestNotification,
        RequestVpn,
    }

    private enum class Stage {
        Notification,
        Vpn,
    }

    data class Request(
        val generation: Long,
        val startAfterGrant: Boolean,
        val callback: (Outcome) -> Unit,
    )

    private data class Pending(
        val request: Request,
        val stage: Stage,
        val staleDelivered: Boolean = false,
    )

    private var pending: Pending? = null
    private var queued: Request? = null

    @Synchronized
    fun begin(
        request: Request,
        notificationGranted: Boolean,
        vpnGranted: Boolean,
    ): Action {
        val current = currentGeneration()
        if (request.generation <= 0 || request.generation != current) {
            stale(request, current, "stale_request")
            return Action.None
        }

        val active = pending
        if (active != null) {
            if (active.request.generation == request.generation) {
                pending = active.copy(request = merge(active.request, request))
                event(
                    "permission_request_started",
                    request.generation,
                    details(current, active.stage, "duplicate_coalesced"),
                )
                return Action.None
            }

            if (!active.staleDelivered) {
                active.request.callback(Outcome.Stale)
            }
            pending = active.copy(staleDelivered = true)
            queued?.callback?.invoke(Outcome.Stale)
            queued = request
            event(
                "permission_result_ignored_stale",
                active.request.generation,
                details(current, active.stage, "superseded_dialog_owner"),
            )
            event(
                "permission_request_started",
                request.generation,
                "current_generation=$current session_state=permission source=queue reason=waiting_for_previous_dialog",
            )
            return Action.None
        }

        return activate(request, notificationGranted, vpnGranted, current)
    }

    @Synchronized
    fun completeNotification(
        resultGranted: Boolean,
        notificationGranted: Boolean,
        vpnGranted: Boolean,
    ): Action = complete(
        expectedStage = Stage.Notification,
        resultGranted = resultGranted,
        notificationGranted = notificationGranted,
        vpnGranted = vpnGranted,
    )

    @Synchronized
    fun completeVpn(
        resultGranted: Boolean,
        notificationGranted: Boolean,
        vpnGranted: Boolean,
    ): Action = complete(
        expectedStage = Stage.Vpn,
        resultGranted = resultGranted,
        notificationGranted = notificationGranted,
        vpnGranted = vpnGranted,
    )

    @Synchronized
    fun cancelAll(reason: String) {
        val current = currentGeneration()
        pending?.let {
            if (!it.staleDelivered) {
                it.request.callback(Outcome.Stale)
            }
            event(
                "permission_result_ignored_stale",
                it.request.generation,
                details(current, it.stage, reason),
            )
        }
        queued?.let {
            it.callback(Outcome.Stale)
            event(
                "permission_result_ignored_stale",
                it.generation,
                "current_generation=$current session_state=permission source=queue reason=$reason",
            )
        }
        pending = null
        queued = null
    }

    private fun complete(
        expectedStage: Stage,
        resultGranted: Boolean,
        notificationGranted: Boolean,
        vpnGranted: Boolean,
    ): Action {
        val active = pending
        val current = currentGeneration()
        if (active == null || active.stage != expectedStage) {
            event(
                "permission_result_ignored_stale",
                active?.request?.generation ?: 0L,
                "current_generation=$current session_state=permission source=${expectedStage.name.lowercase()} reason=duplicate_or_unowned_result",
            )
            return Action.None
        }

        pending = null
        val owner = active.request
        if (active.staleDelivered || owner.generation != current) {
            if (!active.staleDelivered) {
                owner.callback(Outcome.Stale)
            }
            event(
                "permission_result_ignored_stale",
                owner.generation,
                details(current, expectedStage, "generation_changed"),
            )
            return activateQueued(notificationGranted, vpnGranted, current)
        }

        event(
            "permission_result_received",
            owner.generation,
            details(current, expectedStage, if (resultGranted) "granted" else "denied"),
        )
        if (!resultGranted) {
            owner.callback(
                if (expectedStage == Stage.Notification) {
                    Outcome.NotificationDenied
                } else {
                    Outcome.VpnDenied
                },
            )
            return activateQueued(notificationGranted, vpnGranted, current)
        }

        return activate(owner, notificationGranted, vpnGranted, current)
    }

    private fun activateQueued(
        notificationGranted: Boolean,
        vpnGranted: Boolean,
        current: Long,
    ): Action {
        val next = queued ?: return Action.None
        queued = null
        if (next.generation != current) {
            stale(next, current, "queued_generation_changed")
            return Action.None
        }
        return activate(next, notificationGranted, vpnGranted, current)
    }

    private fun activate(
        request: Request,
        notificationGranted: Boolean,
        vpnGranted: Boolean,
        current: Long,
    ): Action {
        if (!notificationGranted) {
            pending = Pending(request, Stage.Notification)
            event(
                "permission_request_started",
                request.generation,
                details(current, Stage.Notification, "dialog_launch"),
            )
            return Action.RequestNotification
        }
        if (!vpnGranted) {
            pending = Pending(request, Stage.Vpn)
            event(
                "permission_request_started",
                request.generation,
                details(current, Stage.Vpn, "dialog_launch"),
            )
            return Action.RequestVpn
        }

        event(
            "permission_result_received",
            request.generation,
            "current_generation=$current session_state=permission source=all reason=already_granted",
        )
        request.callback(Outcome.Granted)
        return Action.None
    }

    private fun merge(first: Request, second: Request) = second.copy(
        startAfterGrant = first.startAfterGrant || second.startAfterGrant,
        callback = { outcome ->
            first.callback(outcome)
            second.callback(outcome)
        },
    )

    private fun stale(request: Request, current: Long, reason: String) {
        event(
            "permission_result_ignored_stale",
            request.generation,
            "current_generation=$current session_state=permission source=request reason=$reason",
        )
        request.callback(Outcome.Stale)
    }

    private fun details(current: Long, stage: Stage, reason: String) =
        "current_generation=$current session_state=permission source=${stage.name.lowercase()} reason=$reason"
}
