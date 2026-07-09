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
import com.zeon.zeon.bg.ServiceConnection
import com.zeon.zeon.bg.ServiceNotification
import com.zeon.zeon.constant.Alert
import com.zeon.zeon.constant.ServiceMode
import com.zeon.zeon.constant.Status
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.LinkedList
import java.util.ArrayDeque


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
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)
    private val vpnPermissionCallbacks = ArrayDeque<(Boolean) -> Unit>()
    private var startServiceAfterVpnPermission = false

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
    fun startService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !ServiceNotification.checkPermission()) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        startService0()
    }

    fun prepareVpn(callback: (Boolean) -> Unit) {
        lifecycleScope.launch(Dispatchers.Main) {
            if (Settings.serviceMode != ServiceMode.VPN) {
                callback(true)
                return@launch
            }
            val waitingForUser = requestVpnPermission(startAfterGrant = false, callback = callback)
            if (!waitingForUser) {
                callback(true)
            }
        }
    }

    private fun startService0() {
        lifecycleScope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                connection.reconnect()
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                if (prepareForServiceStart()) {
                    return@launch
                }
            }
            val intent = Intent(Application.application, Settings.serviceClass())
            withContext(Dispatchers.Main) {
                ContextCompat.startForegroundService(this@MainActivity, intent)
            }
            Settings.startedByUser = true
        }
    }

    private suspend fun prepareForServiceStart() = withContext(Dispatchers.Main) {
        requestVpnPermission(startAfterGrant = true)
    }

    private fun requestVpnPermission(startAfterGrant: Boolean, callback: ((Boolean) -> Unit)? = null): Boolean {
        if (vpnPermissionCallbacks.isNotEmpty()) {
            callback?.let { vpnPermissionCallbacks.add(it) }
            startServiceAfterVpnPermission = startServiceAfterVpnPermission || startAfterGrant
            return true
        }

        return try {
            val intent = VpnService.prepare(this@MainActivity)
            if (intent != null) {
                callback?.let { vpnPermissionCallbacks.add(it) }
                startServiceAfterVpnPermission = startAfterGrant
                prepareLauncher.launch(intent)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            onServiceAlert(Alert.RequestVPNPermission, e.message)
            callback?.invoke(false)
            true
        }
    }

    private fun completeVpnPermissionRequest(granted: Boolean) {
        val callbacks = ArrayList<(Boolean) -> Unit>()
        while (vpnPermissionCallbacks.isNotEmpty()) {
            callbacks.add(vpnPermissionCallbacks.removeFirst())
        }
        val shouldStartService = startServiceAfterVpnPermission && granted
        startServiceAfterVpnPermission = false

        callbacks.forEach { it(granted) }
        if (shouldStartService) {
            startService0()
        } else if (!granted) {
            onServiceAlert(Alert.RequestVPNPermission, null)
        }
    }

    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            if (Settings.dynamicNotification && !isGranted) {
                onServiceAlert(Alert.RequestNotificationPermission, null)
            }
            startService0()
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            completeVpnPermissionRequest(result.resultCode == RESULT_OK)
        }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
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
                startService()
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
