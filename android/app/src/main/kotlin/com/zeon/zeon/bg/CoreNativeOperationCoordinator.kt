package com.zeon.zeon.bg

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes process-global Mobile.setup/start against Mobile.close. */
object CoreNativeOperationCoordinator {
    private val mutex = Mutex()

    suspend fun <T> exclusive(operation: suspend () -> T): T = mutex.withLock {
        operation()
    }
}
