package com.zeon.zeon

import io.flutter.plugin.common.MethodChannel

/** One optional Settings request; lifecycle loss and unavailable UI settle false. */
internal class OptionalActivityRequest {
    private var pending: MethodChannel.Result? = null

    fun begin(result: MethodChannel.Result, launch: () -> Boolean) {
        if (pending != null) {
            result.success(false)
            return
        }
        pending = result
        val launched = try {
            launch()
        } catch (_: Exception) {
            false
        }
        if (!launched) complete(false)
    }

    fun complete(granted: Boolean) {
        val result = pending ?: return
        pending = null
        result.success(granted)
    }
}
