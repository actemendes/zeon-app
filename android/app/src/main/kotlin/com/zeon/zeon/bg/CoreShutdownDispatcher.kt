package com.zeon.zeon.bg

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Go core shutdown may wait for native workers. It must never occupy Android's
 * main looper while input and Flutter lifecycle messages are being delivered.
 */
object CoreShutdownDispatcher {
    private const val DEFAULT_CLOSE_TIMEOUT_MILLIS = 8_000L
    private const val DEFAULT_SETTLE_TIMEOUT_MILLIS = 3_000L
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private var activeClose: Deferred<Unit>? = null

    suspend fun close(
        timeoutMillis: Long = DEFAULT_CLOSE_TIMEOUT_MILLIS,
        closeCore: () -> Unit,
    ): Boolean {
        val close = synchronized(lock) {
            activeClose?.takeUnless { it.isCompleted } ?: scope.async(start = CoroutineStart.LAZY) {
                closeCore()
            }.also { created ->
                activeClose = created
                created.invokeOnCompletion {
                    synchronized(lock) {
                        if (activeClose === created) activeClose = null
                    }
                }
                created.start()
            }
        }
        return withTimeoutOrNull(timeoutMillis) {
            close.await()
            true
        } ?: false
    }

    /** Prevents a new Mobile.setup/start from racing a timed-out old close. */
    suspend fun awaitSettled(timeoutMillis: Long = DEFAULT_SETTLE_TIMEOUT_MILLIS): Boolean {
        val close = synchronized(lock) { activeClose?.takeUnless { it.isCompleted } } ?: return true
        return withTimeoutOrNull(timeoutMillis) {
            runCatching { close.await() }
            true
        } ?: false
    }
}
