package com.zeon.zeon.bg

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Keeps blocking Go Mobile setup off the Activity's main looper. */
object CoreSetupDispatcher {
    suspend fun <T> run(operation: suspend () -> T): T = withContext(Dispatchers.IO) {
        operation()
    }
}
