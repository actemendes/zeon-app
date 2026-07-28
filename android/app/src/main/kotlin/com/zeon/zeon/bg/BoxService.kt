package com.zeon.zeon.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import com.zeon.zeon.Application
import com.zeon.zeon.R
import com.zeon.zeon.Settings
import com.zeon.zeon.constant.Action
import com.zeon.zeon.constant.Alert
import com.zeon.zeon.constant.Status
import com.hiddify.core.mobile.SetupOptions

import go.Seq
import com.hiddify.core.libbox.Libbox
import com.hiddify.core.mobile.Mobile


import com.hiddify.core.libbox.CommandServer
import com.hiddify.core.libbox.CommandServerHandler
import com.hiddify.core.libbox.Notification
import com.hiddify.core.libbox.PlatformInterface
import com.hiddify.core.libbox.SystemProxyStatus
import com.zeon.zeon.MainActivity
import com.zeon.zeon.constant.Bugs
import com.zeon.zeon.utils.GrpcClientProvider
import com.hiddify.core.api.v2.hcommon.Empty
import com.hiddify.core.api.v2.hcore.CoreClient
import com.hiddify.core.api.v2.hcore.SelectOutboundRequest
import com.hiddify.core.api.v2.hcore.UrlTestRequest
import com.squareup.wire.GrpcClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

class BoxService(
        private val service: Service,
        private val platformInterface: PlatformInterface
)  {

    companion object {
        private const val TAG = "A/BoxService"
        private const val OUTBOUND_SELECTOR_TAG = "select"
        private const val AUTO_BALANCER_TAG = "balance"
        const val EXTRA_SESSION_GENERATION = "com.zeon.zeon.extra.SESSION_GENERATION"

        private var initializeOnce = false
        private lateinit var workingDir: File
        private fun initialize() {
            System.setProperty("GODEBUG", "efence=1,stacktraceback=2");
            System.setProperty("GOGC", "off");
            if (initializeOnce) return
            val baseDir = Application.application.filesDir

            baseDir.mkdirs()
            workingDir = Application.application.filesDir
            workingDir.mkdirs()
            val tempDir = Application.application.cacheDir
            tempDir.mkdirs()
            Log.d(TAG, "base dir: ${baseDir.path}")
            Log.d(TAG, "working dir: ${workingDir.path}")
            Log.d(TAG, "temp dir: ${tempDir.path}")

//
            //Mobile.setup(baseDir.path, workingDir.path, tempDir.path,  2L ,"127.0.0.1:{Setting}","",false,this)
//            Libbox.setup(baseDir.path, workingDir.path, tempDir.path, false)

//            Libbox.setup(SetupOptions().also {
//                it.basePath = baseDir.path
//                it.workingPath = workingDir.path
//                it.tempPath = tempDir.path
//                it.fixAndroidStack = Bugs.fixAndroidStack
//
//            })
            Libbox.redirectStderr(File(Settings.workingDir, "stderr.log").path)
            initializeOnce = true
            return
        }

        fun start(generation: Long = VpnSessionCoordinator.next("box_service_start")) {
            val intent = runBlocking {
                withContext(Dispatchers.IO) {
                    Intent(Application.application, Settings.serviceClass())
                        .putExtra(EXTRA_SESSION_GENERATION, generation)
                }
            }
            ContextCompat.startForegroundService(Application.application, intent)
        }

        fun stop(generation: Long = VpnSessionCoordinator.next("box_service_stop")) {
            Application.application.sendBroadcast(
                Intent(Action.SERVICE_CLOSE)
                    .setPackage(Application.application.packageName)
                    .putExtra(EXTRA_SESSION_GENERATION, generation),
            )
        }

        fun markCoreStarted(generation: Long) {
            Application.application.sendBroadcast(
                Intent(Action.SERVICE_CORE_STARTED)
                    .setPackage(Application.application.packageName)
                    .putExtra(EXTRA_SESSION_GENERATION, generation),
            )
        }

    }

    @Volatile
    private var sessionGeneration: Long = 0L
    private val tunOwner = TunDescriptorOwner()
    @Volatile
    private var activeSession: ActiveSession? = null
    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status) { sessionGeneration }
    private val notification = ServiceNotification(status, service)
//    private var boxService: BoxService? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var receiverRegistered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    val generation = intent.getLongExtra(EXTRA_SESSION_GENERATION, 0L)
                    stopService(VpnSessionCoordinator.accept(generation, "close_broadcast"))
                }

                Action.SERVICE_REPING -> {
                    rePingServers()
                }

                Action.SERVICE_CORE_STARTED -> {
                    val generation = intent.getLongExtra(EXTRA_SESSION_GENERATION, 0L)
                    if (VpnSessionCoordinator.isCurrent(generation) && generation == sessionGeneration) {
                        VpnSessionCoordinator.event("core_start_success", generation)
                        VpnSessionCoordinator.event("command_endpoint_ready", generation)
                        publishStatus(Status.Started, generation, "flutter_core_start_confirmed")
                    } else {
                        VpnSessionCoordinator.stale(generation, "core_started_broadcast")
                    }
                }

                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        serviceUpdateIdleMode()
                    }
                }
            }
        }
    }

    /**
     * Restores the built-in automatic balancer after a manual server choice,
     * then immediately schedules URL tests for every server in the selector.
     */
    private fun rePingServers() {
        val generation = sessionGeneration
        val session = activeSession
        if (session == null || session.generation != generation || !session.acceptsOperations()) {
            VpnSessionCoordinator.stale(generation, "manual_refresh_without_active_session")
            return
        }
        session.scope.launch {
            if (!VpnSessionCoordinator.isCurrent(generation)) {
                VpnSessionCoordinator.stale(generation, "manual_refresh_start")
                return@launch
            }
            try {
                Log.i(TAG, "[ManualRefresh] user_refresh_requested source=notification group=$OUTBOUND_SELECTOR_TAG")
                val coreClient = GrpcClientProvider.grpcClient.create(CoreClient::class)
                val currentOutbound = coreClient.GetSystemInfo().executeBlocking(Empty()).current_outbound
                Log.i(TAG, "[ManualRefresh] current_outbound_checked")

                // "balance" is the automatic balancer selected by the core. A
                // manual server selection is reported as its server tag instead.
                if (!currentOutbound.startsWith(AUTO_BALANCER_TAG)) {
                    Log.i(TAG, "[ManualRefresh] restoring_auto_balancer selector=$OUTBOUND_SELECTOR_TAG outbound=$AUTO_BALANCER_TAG")
                    coreClient.SelectOutbound().executeBlocking(
                        SelectOutboundRequest(
                            group_tag = OUTBOUND_SELECTOR_TAG,
                            outbound_tag = AUTO_BALANCER_TAG,
                        ),
                    )
                }

                // Testing the selector recursively schedules tests for all of
                // its children, including the automatic balancer's servers.
                coreClient.UrlTest().executeBlocking(UrlTestRequest(tag = OUTBOUND_SELECTOR_TAG))
                if (!VpnSessionCoordinator.isCurrent(generation)) {
                    VpnSessionCoordinator.stale(generation, "manual_refresh_result")
                    return@launch
                }
                Log.i(TAG, "[ManualRefresh] user_refresh_submitted group=$OUTBOUND_SELECTOR_TAG")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to re-ping servers", e)
            }
        }
    }
    


    private var activeProfileName = ""
    private suspend fun startService(generation: Long) {
        try {
            val session = activeSession
            if (session == null || session.generation != generation || !session.acceptsOperations()) {
                VpnSessionCoordinator.stale(generation, "start_service_without_active_session")
                return
            }
            if (!publishStatus(Status.Starting, generation, "start_service")) return
            Log.d(TAG, "starting service")
            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
            }

            val selectedConfigPath = Settings.activeConfigPath
            if (selectedConfigPath.isBlank()) {
                stopAndAlert(Alert.EmptyConfiguration)
                return
            }

            activeProfileName = Settings.activeProfileName

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
                binder.broadcast {
                    it.onServiceResetLogs(listOf())
                }
            }

            DefaultNetworkMonitor.start()
            Libbox.setMemoryLimit(!Settings.disableMemoryLimit)
            val newService = try {
                Mobile.setup(
                    SetupOptions().also {
                        it.basePath = Settings.baseDir
                        it.workingDir = Settings.workingDir
                        it.tempDir = Settings.tempDir
                        it.fixAndroidStack = com.zeon.zeon.bg.Bugs.fixAndroidStack
                        it.mode=4L//mode.toLong()
                        it.listen= "127.0.0.1:${Settings.grpcServiceModePort}"
                        it.secret=""
                        it.debug = Settings.debugMode
                    },platformInterface)


//                Libbox.newService(content,platformInterface)

            } catch (e: Exception) {
                stopAndAlert(Alert.CreateService, e.message)
                return
            }
            val startsCoreHere = Settings.startCoreAfterStartingService
            VpnSessionCoordinator.event("core_start_requested", generation, "owner=android starts_core=$startsCoreHere")
            val readiness = CoreStartupGate.awaitReady(
                generation = generation,
                startCore = if (startsCoreHere) {
                    { Mobile.start("", "") }
                } else {
                    null
                },
                endpointReady = ::isCommandEndpointReady,
            )
            when (readiness) {
                CoreStartupGate.Result.Ready -> {
                    VpnSessionCoordinator.event("command_endpoint_ready", generation)
                    publishStatus(
                        if (startsCoreHere) Status.Started else Status.CoreReady,
                        generation,
                        if (startsCoreHere) "mobile_start_complete" else "command_endpoint_ready",
                    )
                }
                CoreStartupGate.Result.Superseded -> return
                is CoreStartupGate.Result.Failed -> {
                    VpnSessionCoordinator.event(
                        "core_start_failure",
                        generation,
                        "error=${readiness.error.javaClass.simpleName}",
                        Log.ERROR,
                    )
                    stopAndAlert(Alert.StartService, readiness.error.message)
                    return
                }
                CoreStartupGate.Result.Timeout -> {
                    VpnSessionCoordinator.event("core_start_failure", generation, "error=command_endpoint_timeout", Log.ERROR)
                    stopAndAlert(Alert.StartService, "command endpoint readiness timeout")
                    return
                }
            }
//            if (delayStart) {
//                delay(1000L)
//            }

//            newService.start()
//            boxService = newService
//            commandServer?.setService(boxService)


            withContext(Dispatchers.Main) {
                notification.show(
                    activeProfileName,
                    if (startsCoreHere) R.string.status_started else R.string.status_starting,
                )
            }
            notification.start()
        } catch (e: Exception) {
            stopAndAlert(Alert.StartService, e.message)
            return
        }
    }

    fun serviceReload() {
        runBlocking {
            serviceReload0()
        }
    }

    suspend fun serviceReload0() {
        val previousSession = activeSession
        val generation = VpnSessionCoordinator.next("service_reload")
        sessionGeneration = generation
        notification.close()
        if (previousSession != null) {
            closeSession(previousSession, "service_reload")
        }
        val session = ActiveSession(generation, platformInterface, tunOwner)
        activeSession = session
        publishStatus(Status.Starting, generation, "service_reload")
        
//        boxService?.apply {
//            runCatching {
//                close()
//            }.onFailure {
//                writeLog("service: error when closing: $it")
//            }
//            Seq.destroyRef(refnum)
//        }
//        boxService = null

        session.scope.launch {
            startService(generation)
        }
        
    }

    fun getSystemProxyStatus(): SystemProxyStatus {
        val status = SystemProxyStatus()
        if (service is VPNService) {
            status.available = service.systemProxyAvailable
            status.enabled = service.systemProxyEnabled
        }
        return status
    }

    fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        if (Application.powerManager.isDeviceIdleMode) {
//            boxService?.pause()
            //Mobile.pause()
        } else {
            Mobile.wake()
//            boxService?.wake()
        }
    }

    private fun stopService(generation: Long = VpnSessionCoordinator.next("box_service_stop_internal")) {
        val closingSession = activeSession
        sessionGeneration = VpnSessionCoordinator.accept(generation, "stop_service")
        if (status.value == Status.Stopped && closingSession == null) return
        status.value = Status.Stopping
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.close()
        serviceScope.launch {
            if (closingSession != null) {
                closeSession(closingSession, "stop")
            }
            Settings.startedByUser = false
            withContext(Dispatchers.Main) {
                publishStatus(Status.Stopped, sessionGeneration, "stop_complete")
                service.stopSelf()
            }
            notification.close()
        }
    }

    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        Settings.startedByUser = false
        activeSession?.let { closeSession(it, "failed_start") }
        withContext(Dispatchers.Main) {
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            notification.close()
            binder.broadcast { callback ->
                callback.onServiceAlert(type.ordinal, message)
            }
            status.value = Status.Stopped
        }
    }

    @Suppress("SameReturnValue")
    internal fun onStartCommand(intent: Intent?): Int {
        val requestedGeneration = intent?.getLongExtra(EXTRA_SESSION_GENERATION, 0L) ?: 0L
        val generation = VpnSessionCoordinator.accept(requestedGeneration, "service_start_command")
        if (requestedGeneration > 0 && generation != requestedGeneration) {
            return Service.START_NOT_STICKY
        }
        sessionGeneration = generation
        if (status.value != Status.Stopped || activeSession?.acceptsOperations() == true) {
            VpnSessionCoordinator.event(
                "core_already_started_conflict",
                generation,
                "status=${status.value}",
                Log.ERROR,
            )
            return Service.START_NOT_STICKY
        }
        status.value = Status.Starting
        val session = ActiveSession(generation, platformInterface, tunOwner)
        activeSession = session

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(Action.SERVICE_CLOSE)
                addAction(Action.SERVICE_REPING)
                addAction(Action.SERVICE_CORE_STARTED)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        session.scope.launch {
            Settings.startedByUser = true
            initialize()
//            try {
//                startCommandServer()
//            } catch (e: Exception) {
//                stopAndAlert(Alert.StartCommandServer, e.message)
//                return@launch
//            }
            startService(generation)
        }
        return Service.START_NOT_STICKY
    }

    fun onBind(intent: Intent): IBinder {
        return binder
    }

    fun onDestroy() {
        val closingSession = activeSession
        if (closingSession != null) {
            val destroyGeneration = VpnSessionCoordinator.next("service_destroy")
            sessionGeneration = destroyGeneration
            runBlocking {
                val completed = withTimeoutOrNull(12_000) {
                    closeSession(closingSession, "on_destroy")
                    true
                } ?: false
                if (!completed) {
                    VpnSessionCoordinator.event(
                        "terminal_failure",
                        closingSession.generation,
                        "phase=on_destroy error=teardown_timeout",
                        Log.ERROR,
                    )
                }
            }
        }
        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        binder.close()
        serviceScope.cancel()
        mainScope.cancel()
    }

    fun onRevoke() {
        stopService(VpnSessionCoordinator.next("vpn_revoke"))
    }

    internal fun currentSessionGeneration(): Long = sessionGeneration

    internal fun openTun(
        generation: Long,
        descriptor: android.os.ParcelFileDescriptor,
        validate: () -> Unit,
    ): Int {
        val session = activeSession
        if (session == null || session.generation != generation || !session.acceptsOperations()) {
            descriptor.close()
            VpnSessionCoordinator.stale(generation, "open_tun_without_active_session")
            error("VPN session is not accepting TUN requests")
        }
        return tunOwner.open(generation, descriptor, validate)
    }

    private suspend fun closeSession(session: ActiveSession, reason: String) {
        session.close(
            reason = reason,
            closeCommandClientsAndListeners = {
                // Flutter owns gRPC client objects; Android owns the endpoint and
                // removes all native callbacks before stopping it.
                DefaultNetworkMonitor.setListener(null)
            },
            stopCore = {
                withContext(Dispatchers.Main) {
                    Mobile.close(4L)
                }
            },
            closeCommandServer = { server ->
                server?.let {
                    runCatching { it.close() }
                    runCatching { Seq.destroyRef(it.refnum) }
                }
            },
            closePlatform = {
                DefaultNetworkMonitor.setListener(null)
            },
            clearNetwork = {
                DefaultNetworkMonitor.stop()
                if (activeSession === session) {
                    activeSession = null
                }
            },
        )
    }

    private fun publishStatus(next: Status, generation: Long, source: String): Boolean {
        if (!VpnSessionCoordinator.isCurrent(generation) || generation != sessionGeneration) {
            VpnSessionCoordinator.stale(generation, "status/$source")
            return false
        }
        VpnSessionCoordinator.event(
            "vpn_status",
            generation,
            "status=${next.name} source=$source",
        )
        status.postValue(next)
        return true
    }

    private fun isCommandEndpointReady(): Boolean {
        return try {
            val client = GrpcClientProvider.grpcClient.create(CoreClient::class)
            client.GetSystemInfo().executeBlocking(Empty())
            true
        } catch (_: Exception) {
            false
        }
    }

    internal fun sendNotification(notification: Notification) {
        return
        val builder =
            NotificationCompat.Builder(service, notification.identifier).setShowWhen(false)
                .setContentTitle(notification.title).setContentText(notification.body)
                .setOnlyAlertOnce(true).setSmallIcon(R.drawable.ic_launcher_foreground)
                .setCategory(NotificationCompat.CATEGORY_EVENT)
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(true)
        if (!notification.subtitle.isNullOrBlank()) {
            builder.setContentInfo(notification.subtitle)
        }
        if (!notification.openURL.isNullOrBlank()) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
                    Intent(
                        service,
                        MainActivity::class.java,
                    ).apply {
                        setAction(Action.SERVICE).setData(Uri.parse(notification.openURL))
                        setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    },
                    ServiceNotification.flags,
                ),
            )
        }
        mainScope.launch {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Application.notification.createNotificationChannel(
                    NotificationChannel(
                        notification.identifier,
                        notification.typeName,
                        NotificationManager.IMPORTANCE_HIGH,
                    ),
                )
            }
            Application.notification.notify(notification.typeID, builder.build())
        }
    }

     fun writeDebugMessage(message: String?) {
        val safeMessage = message ?: return
        binder.broadcast {
            it.onServiceWriteLog(safeMessage)
        }
    }

}
