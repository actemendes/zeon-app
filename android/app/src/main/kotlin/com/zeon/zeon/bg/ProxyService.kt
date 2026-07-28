package com.zeon.zeon.bg

import android.app.Service
import android.content.Intent
import com.hiddify.core.libbox.Notification

class ProxyService :
    Service(),
    PlatformInterfaceWrapper {
    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = service.onStartCommand(intent)

    override fun onBind(intent: Intent) = service.onBind(intent)

    override fun onDestroy() {
        try {
            service.onDestroy()
        } finally {
            super.onDestroy()
        }
    }

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)
}
