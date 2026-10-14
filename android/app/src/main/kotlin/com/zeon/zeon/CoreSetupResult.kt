package com.zeon.zeon

import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException

/** Always settles Flutter bootstrap, including a failed or cancelled native setup. */
internal suspend fun completeCoreSetup(result: MethodChannel.Result, setup: suspend () -> Unit) {
    try {
        setup()
    } catch (cancelled: CancellationException) {
        result.error("core_setup_cancelled", "Native core initialization was cancelled", null)
        throw cancelled
    } catch (_: LinkageError) {
        result.error("core_setup_failed", "Native core initialization failed", null)
        return
    } catch (_: Exception) {
        // Native exception messages may contain paths/configuration. Keep the
        // bridge error useful without copying those values into Dart logs.
        result.error("core_setup_failed", "Native core initialization failed", null)
        return
    }
    // Keep reply delivery outside the try block: a delivery exception must not
    // result in a second reply to the same method call.
    result.success("")
}
