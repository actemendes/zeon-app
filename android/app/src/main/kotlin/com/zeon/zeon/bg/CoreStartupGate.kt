package com.zeon.zeon.bg

import kotlinx.coroutines.delay

internal object CoreStartupGate {
    sealed interface Result {
        data object Ready : Result
        data object Superseded : Result
        data class Failed(val error: Throwable) : Result
        data object Timeout : Result
    }

    suspend fun awaitReady(
        generation: Long,
        startCore: (() -> Unit)?,
        endpointReady: () -> Boolean,
        maxAttempts: Int = 20,
        delayMillis: Long = 100,
    ): Result {
        if (!VpnSessionCoordinator.isCurrent(generation)) return Result.Superseded
        try {
            startCore?.invoke()
        } catch (error: Throwable) {
            return Result.Failed(error)
        }
        repeat(maxAttempts.coerceAtLeast(1)) { attempt ->
            if (!VpnSessionCoordinator.isCurrent(generation)) return Result.Superseded
            val ready = try {
                endpointReady()
            } catch (_: Throwable) {
                false
            }
            if (ready) return Result.Ready
            if (attempt + 1 < maxAttempts && delayMillis > 0) {
                delay(delayMillis)
            }
        }
        return Result.Timeout
    }
}
