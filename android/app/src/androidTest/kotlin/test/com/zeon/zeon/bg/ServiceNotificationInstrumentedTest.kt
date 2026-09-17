package test.com.zeon.zeon.bg

import android.app.Service
import android.content.Intent
import android.os.IBinder
import androidx.lifecycle.MutableLiveData
import com.zeon.zeon.bg.ServiceNotification
import com.zeon.zeon.bg.VpnNotificationActionReceiver
import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.Application
import com.zeon.zeon.constant.Action
import com.zeon.zeon.constant.Status
import com.zeon.zeon.Settings
import com.zeon.zeon.bg.VpnSessionPhase
import com.zeon.zeon.bg.VpnSessionSnapshotCoordinator
import com.zeon.zeon.bg.VpnStopSource
import com.hiddify.core.api.v2.hcore.SystemInfo

class ServiceNotificationInstrumentedTest {
    fun disabledDynamicNotificationStillUpdatesConnectedOutbound() {
        val service = object : Service() {
            override fun onBind(intent: Intent?): IBinder? = null
        }
        val notification = ServiceNotification(MutableLiveData(Status.Started), service)
        val generation = VpnSessionCoordinator.next("snapshot_without_dynamic_notification_test")
        val previousSetting = Settings.dynamicNotification
        try {
            Settings.dynamicNotification = false
            notification.installSystemInfoGenerationForTesting(generation)
            VpnSessionSnapshotCoordinator.begin(generation, "connect")
            VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.CONNECTED) {
                it.copy(coreReady = true, coreStarted = true, commandEndpointReady = true,
                    tunnelReady = true, protectSucceeded = true, selectedOutboundId = "old")
            }
            // An unattached Service cannot render notifications. Publishing the
            // native outbound must nevertheless work while rendering is disabled.
            notification.updateStatus(SystemInfo(), SystemInfo(current_outbound = "Server B"))
            val snapshot = VpnSessionSnapshotCoordinator.current()
            check(snapshot.provesConnected())
            check(snapshot.selectedOutboundLabel == "Server B")
            check(snapshot.selectedOutboundId != "old")
        } finally {
            Settings.dynamicNotification = previousSetting
            notification.detachSystemInfoListener(expectedGeneration = generation)
            VpnSessionSnapshotCoordinator.publishDisconnected(generation, VpnStopSource.FLUTTER)
        }
    }

    fun staleCleanupCannotDetachANewerGeneration() {
        val service = object : Service() {
            override fun onBind(intent: Intent?): IBinder? = null
        }
        val notification = ServiceNotification(MutableLiveData(Status.Stopped), service)
        notification.installSystemInfoGenerationForTesting(20L)

        check(notification.detachSystemInfoListener(expectedGeneration = 19L) == null)
        check(notification.activeSystemInfoGenerationForTesting() == 20L)
        check(notification.detachSystemInfoListener(maximumGeneration = 19L) == null)
        check(notification.activeSystemInfoGenerationForTesting() == 20L)

        val detached = notification.detachSystemInfoListener(expectedGeneration = 20L)
        check(detached?.generation == 20L)
        check(notification.activeSystemInfoGenerationForTesting() == 0L)
    }

    fun notificationStopUsesOneExplicitProcessReceiverAndOneGeneration() {
        val context = Application.application
        val intent = ServiceNotification.stopIntent(context)
        check(intent.action == Action.SERVICE_CLOSE_REQUEST)
        check(intent.component?.className == VpnNotificationActionReceiver::class.java.name)

        val before = VpnSessionCoordinator.current()
        VpnNotificationActionReceiver().onReceive(context, intent)
        check(VpnSessionCoordinator.current() == before + 1L) {
            "one notification action reserved more than one Stop generation"
        }
    }
}
