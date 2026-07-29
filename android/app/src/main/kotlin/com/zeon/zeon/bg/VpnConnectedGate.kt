package com.zeon.zeon.bg

/** Pure, deterministic final gate for publishing Android Started. */
internal object VpnConnectedGate {
    data class Evidence(
        val permissionGranted: Boolean,
        val mobileStartSucceeded: Boolean,
        val commandEndpointReady: Boolean,
        val tunOpened: Boolean,
        val postTunProtectSucceeded: Boolean,
        val generationCurrent: Boolean,
        val sessionAcceptingOperations: Boolean,
    )

    sealed interface Result {
        data object Ready : Result
        data class Rejected(val missing: List<String>) : Result
    }

    fun evaluate(evidence: Evidence): Result {
        val missing = buildList {
            if (!evidence.permissionGranted) add("permission")
            if (!evidence.mobileStartSucceeded) add("mobile_start")
            if (!evidence.commandEndpointReady) add("command_endpoint")
            if (!evidence.tunOpened) add("tun")
            if (!evidence.postTunProtectSucceeded) add("post_tun_protect")
            if (!evidence.generationCurrent) add("generation")
            if (!evidence.sessionAcceptingOperations) add("session_closing")
        }
        return if (missing.isEmpty()) Result.Ready else Result.Rejected(missing)
    }
}
