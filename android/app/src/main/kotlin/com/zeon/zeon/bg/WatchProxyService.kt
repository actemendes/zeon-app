package com.zeon.zeon.bg

import android.app.Service
import android.content.Intent
import android.os.IBinder
import com.zeon.zeon.Settings

/** Watch-only foreground core owner. It never creates or claims a VPN tunnel. */
class WatchProxyService : Service(), PlatformInterfaceWrapper {
    private val box = BoxService(this) { this }
    var backupOnly = false
        private set

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!Settings.isWatch) { stopSelf(); return START_NOT_STICKY }
        backupOnly = intent?.getBooleanExtra(WatchBackupBridgeService.EXTRA_BACKUP, false) == true
        return box.onStartCommand(intent)
    }
    override fun sendNotification(notification: com.hiddify.core.libbox.Notification) {}

    override fun onBind(intent: Intent): IBinder = box.onBind(intent)
    override fun onDestroy() {
        try { WatchProxySettings.stop(this, Long.MAX_VALUE, destroyed = true); box.onDestroy() }
        finally { super.onDestroy() }
    }
}
