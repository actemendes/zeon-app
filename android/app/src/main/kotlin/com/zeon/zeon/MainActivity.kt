package com.zeon.zeon

import android.annotation.SuppressLint
import android.Manifest
import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import com.zeon.zeon.bg.BoxService
import com.zeon.zeon.bg.ServiceConnection
import com.zeon.zeon.bg.ServiceNotification
import com.zeon.zeon.bg.StartPermissionRequestCoordinator
import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.constant.Alert
import com.zeon.zeon.constant.ServiceMode
import com.zeon.zeon.constant.Status
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.LinkedList


class MainActivity : FlutterFragmentActivity(), ServiceConnection.Callback {
    companion object {
        lateinit var instance: MainActivity
    }

    private val connection = ServiceConnection(this, this)

    val logList = LinkedList<String>()
    var logCallback: ((Boolean) -> Unit)? = null
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceGeneration = MutableLiveData(0L)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)
    private val startPermissionRequests = StartPermissionRequestCoordinator()
    private var serviceLaunchGeneration = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        instance = this
        reconnect()
        flutterEngine.plugins.add(MethodHandler(lifecycleScope))
        flutterEngine.plugins.add(PlatformSettingsHandler())
        flutterEngine.plugins.add(EventHandler())
        flutterEngine.plugins.add(LogHandler())
//        flutterEngine.plugins.add(GroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(ActiveGroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(StatsChannel(lifecycleScope))
    }

    fun reconnect() {
        connection.reconnect()
    }

    @SuppressLint("NewApi")
    fun startService(generation: Long = VpnSessionCoordinator.next("main_activity_start")) {
        val acceptedGeneration = VpnSessionCoordinator.accept(generation, "main_activity_start")
        requestStartPermissions(acceptedGeneration, startAfterGrant = true)
    }

    internal fun prepareVpn(generation: Long, callback: (StartPermissionRequestCoordinator.Outcome) -> Unit) {
        lifecycleScope.launch(Dispatchers.Main) {
            if (Settings.serviceMode != ServiceMode.VPN) {
                callback(StartPermissionRequestCoordinator.Outcome.Granted)
                return@launch
            }
            requestStartPermissions(generation, startAfterGrant = false, callback = callback)
        }
    }

    @Synchronized
    private fun startServiceAfterPermissions(generation: Long) {
        if (!VpnSessionCoordinator.isCurrent(generation)) {
            VpnSessionCoordinator.event(
                "stale_completion_ignored",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=permission source=service_launch reason=stale_generation",
            )
            return
        }
        if (serviceLaunchGeneration == generation) {
            VpnSessionCoordinator.event(
                "stale_completion_ignored",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=permission source=service_launch reason=duplicate_launch",
            )
            return
        }
        serviceLaunchGeneration = generation
        val acceptedGeneration = VpnSessionCoordinator.accept(generation, "main_activity_start_service")
        lifecycleScope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                connection.reconnect()
            }
            val intent = Intent(Application.application, Settings.serviceClass())
                .putExtra(BoxService.EXTRA_SESSION_GENERATION, acceptedGeneration)
            withContext(Dispatchers.Main) {
                ContextCompat.startForegroundService(this@MainActivity, intent)
            }
            Settings.startedByUser = true
        }
    }

    private fun requestStartPermissions(
        generation: Long,
        startAfterGrant: Boolean,
        callback: ((StartPermissionRequestCoordinator.Outcome) -> Unit)? = null,
    ) {
        val completion = callback ?: {}
        try {
            val action = startPermissionRequests.begin(
                StartPermissionRequestCoordinator.Request(generation, startAfterGrant) { outcome ->
                    when (outcome) {
                        StartPermissionRequestCoordinator.Outcome.Granted -> {
                            if (startAfterGrant) {
                                startServiceAfterPermissions(generation)
                            }
                        }
                        StartPermissionRequestCoordinator.Outcome.NotificationDenied -> {
                            if (VpnSessionCoordinator.isCurrent(generation)) {
                                onServiceAlert(Alert.RequestNotificationPermission, null, generation)
                            }
                        }
                        StartPermissionRequestCoordinator.Outcome.VpnDenied -> {
                            if (VpnSessionCoordinator.isCurrent(generation)) {
                                onServiceAlert(Alert.RequestVPNPermission, null, generation)
                            }
                        }
                        StartPermissionRequestCoordinator.Outcome.Stale -> Unit
                    }
                    completion(outcome)
                },
                notificationGranted = notificationPermissionGranted(),
                vpnGranted = vpnPermissionGranted(),
            )
            executePermissionAction(action)
        } catch (e: Exception) {
            if (VpnSessionCoordinator.isCurrent(generation)) {
                onServiceAlert(Alert.RequestVPNPermission, e.message, generation)
                completion(StartPermissionRequestCoordinator.Outcome.VpnDenied)
            } else {
                completion(StartPermissionRequestCoordinator.Outcome.Stale)
            }
        }
    }

    private fun executePermissionAction(action: StartPermissionRequestCoordinator.Action) {
        when (action) {
            StartPermissionRequestCoordinator.Action.None -> Unit
            StartPermissionRequestCoordinator.Action.RequestNotification ->
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            StartPermissionRequestCoordinator.Action.RequestVpn -> {
                val intent = VpnService.prepare(this)
                if (intent == null) {
                    executePermissionAction(
                        startPermissionRequests.completeVpn(
                            resultGranted = true,
                            notificationGranted = notificationPermissionGranted(),
                            vpnGranted = true,
                        ),
                    )
                } else {
                    prepareLauncher.launch(intent)
                }
            }
        }
    }

    private fun notificationPermissionGranted() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || ServiceNotification.checkPermission()

    private fun vpnPermissionGranted() =
        Settings.serviceMode != ServiceMode.VPN || VpnService.prepare(this) == null

    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            executePermissionAction(
                startPermissionRequests.completeNotification(
                    resultGranted = isGranted,
                    notificationGranted = notificationPermissionGranted(),
                    vpnGranted = vpnPermissionGranted(),
                ),
            )
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            val granted = result.resultCode == RESULT_OK && vpnPermissionGranted()
            executePermissionAction(
                startPermissionRequests.completeVpn(
                    resultGranted = granted,
                    notificationGranted = notificationPermissionGranted(),
                    vpnGranted = vpnPermissionGranted(),
                ),
            )
        }

    override fun onServiceStatusChanged(status: Status, generation: Long) {
        serviceGeneration.postValue(generation)
        serviceStatus.postValue(status)
    }

    override fun onServiceDisconnected(generation: Long) {
        if (generation == 0L || VpnSessionCoordinator.isCurrent(generation)) {
            serviceGeneration.postValue(generation)
            serviceStatus.postValue(Status.Stopped)
        } else {
            VpnSessionCoordinator.stale(generation, "main_activity_service_disconnect")
        }
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        onServiceAlert(type, message, VpnSessionCoordinator.current())
    }

    private fun onServiceAlert(type: Alert, message: String?, generation: Long) {
        if (!VpnSessionCoordinator.isCurrent(generation)) {
            VpnSessionCoordinator.event(
                "stale_exception_ignored",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=alert source=android_alert reason=${type.name}",
            )
            return
        }
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message, generation))
    }




    override fun onDestroy() {
        startPermissionRequests.cancelAll("activity_destroyed")
        connection.disconnect()
        super.onDestroy()
    }
}
