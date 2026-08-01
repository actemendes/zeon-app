package com.zeon.zeon.bg

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull

/** Runs each teardown step independently so one stuck native/listener call cannot hide TUN cleanup. */
object SessionCloseDispatcher {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    suspend fun runStep(
        timeoutMillis: Long,
        action: suspend () -> Unit,
    ): Result<Unit>? {
        val step = scope.async(start = CoroutineStart.LAZY) {
            runCatching { action() }
        }
        step.start()
        return withTimeoutOrNull(timeoutMillis) {
            step.await()
        }
    }
}
