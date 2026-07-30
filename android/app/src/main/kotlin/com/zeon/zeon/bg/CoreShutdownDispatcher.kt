package com.zeon.zeon.bg

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Go core shutdown may wait for native workers. It must never occupy Android's
 * main looper while input and Flutter lifecycle messages are being delivered.
 */
object CoreShutdownDispatcher {
    suspend fun close(closeCore: () -> Unit) {
        withContext(Dispatchers.IO) {
            closeCore()
        }
    }
}
