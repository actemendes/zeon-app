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

class ServiceNotificationInstrumentedTest {
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
