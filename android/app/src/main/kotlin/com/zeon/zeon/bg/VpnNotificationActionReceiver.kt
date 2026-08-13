package com.zeon.zeon.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.zeon.zeon.constant.Action

/**
 * A notification click reaches exactly one manifest receiver. That receiver
 * reserves one process-wide Stop generation before BoxService fans the typed
 * request out to every transient service owner.
 */
class VpnNotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Action.SERVICE_CLOSE_REQUEST) return
        BoxService.stop(source = VpnStopSource.NOTIFICATION)
    }
}
