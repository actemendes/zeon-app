package com.zeon.zeon

import android.annotation.SuppressLint
import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import com.zeon.zeon.bg.BoxService
import com.zeon.zeon.bg.ServiceConnection
import com.zeon.zeon.bg.ServiceNotification
import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.bg.VpnPermissionRequestCoordinator
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

        const val VPN_PERMISSION_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1010
    }

    private val connection = ServiceConnection(this, this)

    val logList = LinkedList<String>()
    var logCallback: ((Boolean) -> Unit)? = null
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceGeneration = MutableLiveData(0L)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)
    private val vpnPermissionRequests = VpnPermissionRequestCoordinator()
    private var pendingStartGeneration = 0L
    private var notificationPermissionGeneration = 0L

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
        pendingStartGeneration = VpnSessionCoordinator.accept(generation, "main_activity_start")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !ServiceNotification.checkPermission()) {
            notificationPermissionGeneration = pendingStartGeneration
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        startService0(pendingStartGeneration)
    }

    internal fun prepareVpn(generation: Long, callback: (VpnPermissionRequestCoordinator.Outcome) -> Unit) {
        lifecycleScope.launch(Dispatchers.Main) {
            if (Settings.serviceMode != ServiceMode.VPN) {
                callback(VpnPermissionRequestCoordinator.Outcome.Granted)
                return@launch
            }
            requestVpnPermission(generation, startAfterGrant = false, callback = callback)
        }
    }

    private fun startService0(
        generation: Long = pendingStartGeneration.takeIf { it > 0 }
            ?: VpnSessionCoordinator.next("main_activity_start_fallback"),
    ) {
        val acceptedGeneration = VpnSessionCoordinator.accept(generation, "main_activity_start_service")
        lifecycleScope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                connection.reconnect()
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                if (prepareForServiceStart(acceptedGeneration)) {
                    return@launch
                }
            }
            val intent = Intent(Application.application, Settings.serviceClass())
                .putExtra(BoxService.EXTRA_SESSION_GENERATION, acceptedGeneration)
            withContext(Dispatchers.Main) {
                ContextCompat.startForegroundService(this@MainActivity, intent)
            }
            Settings.startedByUser = true
        }
    }

    private suspend fun prepareForServiceStart(generation: Long) = withContext(Dispatchers.Main) {
        requestVpnPermission(generation, startAfterGrant = true)
    }

    private fun requestVpnPermission(
        generation: Long,
        startAfterGrant: Boolean,
        callback: ((VpnPermissionRequestCoordinator.Outcome) -> Unit)? = null,
    ): Boolean {
        val completion = callback ?: {}
        return try {
            val intent = VpnService.prepare(this@MainActivity)
            if (intent != null) {
                val launch = vpnPermissionRequests.request(
                    VpnPermissionRequestCoordinator.Request(generation, startAfterGrant, completion),
                )
                if (launch) prepareLauncher.launch(intent)
                true
            } else {
                vpnPermissionRequests.completeAlreadyGranted(generation, completion)
                false
            }
        } catch (e: Exception) {
            if (VpnSessionCoordinator.isCurrent(generation)) {
                onServiceAlert(Alert.RequestVPNPermission, e.message, generation)
                completion(VpnPermissionRequestCoordinator.Outcome.Denied)
            } else {
                completion(VpnPermissionRequestCoordinator.Outcome.Stale)
            }
            true
        }
    }

    private fun completeVpnPermissionRequest(granted: Boolean) {
        val completed = vpnPermissionRequests.complete(granted) ?: return
        if (granted && completed.startAfterGrant) {
            startService0(completed.generation)
        } else if (!granted && VpnSessionCoordinator.isCurrent(completed.generation)) {
            onServiceAlert(Alert.RequestVPNPermission, null, completed.generation)
        }
    }

    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            val generation = notificationPermissionGeneration
            notificationPermissionGeneration = 0L
            if (!VpnSessionCoordinator.isCurrent(generation)) {
                VpnSessionCoordinator.event(
                    "stale_completion_ignored",
                    generation,
                    "current_generation=${VpnSessionCoordinator.current()} session_state=permission source=notification_permission reason=stale_result",
                )
                return@registerForActivityResult
            }
            if (Settings.dynamicNotification && !isGranted) {
                onServiceAlert(Alert.RequestNotificationPermission, null, generation)
            }
            startService0(generation)
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            completeVpnPermissionRequest(result.resultCode == RESULT_OK)
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
        connection.disconnect()
        super.onDestroy()
    }

    @SuppressLint("NewApi")
    private fun grantNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startService(pendingStartGeneration)
            } else {
                onServiceAlert(Alert.RequestNotificationPermission, null)
                startService0()
            }
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            completeVpnPermissionRequest(resultCode == RESULT_OK)
        } else if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) startService()
            else {
                onServiceAlert(Alert.RequestNotificationPermission, null)
                startService0()
            }
        }
    }
}
