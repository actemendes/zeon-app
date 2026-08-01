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
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService as AndroidVpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class BoxService(
        private val service: Service,
        private val platformInterface: PlatformInterface
)  {

    companion object {
        private const val TAG = "A/BoxService"
        private const val OUTBOUND_SELECTOR_TAG = "select"
        private const val AUTO_BALANCER_TAG = "balance"
        const val EXTRA_SESSION_GENERATION = "com.zeon.zeon.extra.SESSION_GENERATION"
        const val EXTRA_STOP_SOURCE = "com.zeon.zeon.extra.STOP_SOURCE"
        private const val STOP_FALLBACK_INITIAL_DELAY_MILLIS = 300L
        private const val STOP_FALLBACK_POLL_MILLIS = 200L
        private const val STOP_FALLBACK_TIMEOUT_MILLIS = 10_000L
        private val stopFallbackHandler = Handler(Looper.getMainLooper())
        private val activeInstances = ConcurrentHashMap.newKeySet<BoxService>()
        private val destructionScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        init {
            TunDescriptorOwner.setOwnershipSettledListener {
                scheduleTerminalSettlementProbe()
            }
            CoreProcessOwnerCoordinator.setOwnershipSettledListener {
                scheduleTerminalSettlementProbe()
            }
        }

        private fun scheduleTerminalSettlementProbe() {
            stopFallbackHandler.post {
                val snapshot = VpnSessionSnapshotCoordinator.current()
                if (
                    snapshot.requestedAction == "stop" &&
                    snapshot.generation == VpnSessionCoordinator.current()
                ) {
                    publishTerminalIfOwnersSettled(snapshot.generation, snapshot.stopSource)
                }
            }
        }

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

        fun stop(
            generation: Long = 0L,
            source: VpnStopSource = VpnStopSource.INTERNAL,
        ): Boolean = requestStop(generation, source, preemptive = false) != null

        fun stopPreemptively(
            requestedGeneration: Long,
            source: VpnStopSource,
        ): Long = requireNotNull(requestStop(requestedGeneration, source, preemptive = true))

        fun stopForReplacement(generation: Long): Boolean {
            return when (VpnLifecycleIntentCoordinator.reserveReplacementStop(generation)) {
                VpnLifecycleIntentCoordinator.ReplacementStopDecision.REJECTED -> false
                VpnLifecycleIntentCoordinator.ReplacementStopDecision.ALREADY_ACCEPTED -> true
                VpnLifecycleIntentCoordinator.ReplacementStopDecision.DISPATCH -> {
                    val source = VpnStopSource.REPLACEMENT
                    dispatchStopToActiveOwners(generation, source)
                    Application.application.sendBroadcast(
                        Intent(Action.SERVICE_CLOSE)
                            .setPackage(Application.application.packageName)
                            .putExtra(EXTRA_SESSION_GENERATION, generation)
                            .putExtra(EXTRA_STOP_SOURCE, source.wireValue),
                    )
                    scheduleTerminalFallback(generation, source)
                    true
                }
            }
        }

        internal fun newestStopSource(
            previous: VpnStopSource,
            incoming: VpnStopSource,
        ): VpnStopSource = when {
            incoming == VpnStopSource.NONE -> previous
            incoming == VpnStopSource.REPLACEMENT && previous.clearsExpectedRunning -> previous
            else -> incoming
        }

        private fun requestStop(
            requestedGeneration: Long,
            source: VpnStopSource,
            preemptive: Boolean,
        ): Long? {
            val acceptedGeneration = VpnLifecycleIntentCoordinator.reserveStop(
                requestedGeneration = requestedGeneration,
                preemptive = preemptive,
                reason = "box_service_stop/${source.wireValue}",
            ) ?: return null
            if (source.clearsExpectedRunning) {
                Settings.startedByUser = false
            }
            // Dispatch directly to every live owner as well as broadcasting.
            // The registry covers FAILED/stopped services whose dynamic receiver
            // is already gone; the package broadcast preserves compatibility
            // with a service-mode transition already being created by Android.
            dispatchStopToActiveOwners(acceptedGeneration, source)
            Application.application.sendBroadcast(
                Intent(Action.SERVICE_CLOSE)
                    .setPackage(Application.application.packageName)
                    .putExtra(EXTRA_SESSION_GENERATION, acceptedGeneration)
                    .putExtra(EXTRA_STOP_SOURCE, source.wireValue),
            )
            scheduleTerminalFallback(acceptedGeneration, source)
            return acceptedGeneration
        }

        private fun dispatchStopToActiveOwners(generation: Long, source: VpnStopSource) {
            val dispatch = Runnable {
                activeInstances.toList().forEach { owner ->
                    owner.receiveStop(generation, source, "direct_owner")
                }
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                dispatch.run()
            } else {
                stopFallbackHandler.post(dispatch)
            }
        }

        private fun publishTerminalIfOwnersSettled(
            generation: Long,
            source: VpnStopSource,
        ): Boolean {
            if (!VpnSessionCoordinator.isCurrent(generation)) return false
            val owningServices = activeInstances.count { it.hasSessionOwnership() }
            val processTunOwned = TunDescriptorOwner.hasProcessWideOwnership()
            val processCoreOwned = CoreProcessOwnerCoordinator.hasOwner()
            if (owningServices > 0 || processTunOwned || processCoreOwned) {
                VpnSessionCoordinator.event(
                    "stop_terminal_deferred",
                    generation,
                    "source=${source.wireValue} remaining_owners=$owningServices tun_owned=$processTunOwned core_owned=$processCoreOwned",
                )
                return false
            }
            if (source == VpnStopSource.REPLACEMENT) {
                val completed = VpnLifecycleIntentCoordinator.completeReplacementStop(generation) {
                    VpnSessionSnapshotCoordinator.publishDisconnected(generation, source)
                }
                if (!completed) {
                    VpnSessionCoordinator.stale(generation, "replacement_terminal_after_start")
                }
                return completed
            }
            VpnSessionSnapshotCoordinator.publishDisconnected(generation, source)
            return true
        }

        private fun scheduleTerminalFallback(generation: Long, source: VpnStopSource) {
            val deadline = SystemClock.elapsedRealtime() + STOP_FALLBACK_TIMEOUT_MILLIS
            lateinit var probe: Runnable
            probe = Runnable {
                if (!VpnSessionCoordinator.isCurrent(generation)) return@Runnable

                val snapshot = VpnSessionSnapshotCoordinator.current()
                when {
                    snapshot.generation > generation -> {
                        // A later explicit operation superseded this Stop.
                    }

                    snapshot.generation == generation &&
                        snapshot.phase == VpnSessionPhase.DISCONNECTED -> {
                        // The requested terminal state was published.
                    }

                    activeInstances.none { it.hasSessionOwnership() } -> {
                        if (!VpnSessionCoordinator.isCurrent(generation)) return@Runnable
                        VpnSessionCoordinator.event(
                            "stop_without_service_owner",
                            generation,
                            "source=${source.wireValue} action=publish_disconnected",
                        )
                        val published = publishTerminalIfOwnersSettled(generation, source)
                        if (!published) {
                            if (SystemClock.elapsedRealtime() < deadline) {
                                stopFallbackHandler.postDelayed(probe, STOP_FALLBACK_POLL_MILLIS)
                            } else {
                                publishTeardownTimeout(generation, source, snapshot.phase)
                            }
                        }
                    }

                    SystemClock.elapsedRealtime() < deadline -> {
                        stopFallbackHandler.postDelayed(probe, STOP_FALLBACK_POLL_MILLIS)
                    }

                    else -> {
                        publishTeardownTimeout(generation, source, snapshot.phase)
                    }
                }
            }
            stopFallbackHandler.postDelayed(probe, STOP_FALLBACK_INITIAL_DELAY_MILLIS)
        }

        private fun publishTeardownTimeout(
            generation: Long,
            source: VpnStopSource,
            phase: VpnSessionPhase,
        ) {
            if (!VpnSessionCoordinator.isCurrent(generation)) return
            VpnSessionCoordinator.event(
                "stop_terminal_fallback_expired",
                generation,
                "source=${source.wireValue} phase=${phase.name}",
                Log.ERROR,
            )
            VpnSessionSnapshotCoordinator.failure(
                generation,
                code = "teardown_timeout",
                owner = "android_service",
                recoverable = true,
            )
        }

        @Volatile
        private var activeInstance: BoxService? = null

        suspend fun markCoreStarted(generation: Long): Boolean {
            val instance = activeInstance
            if (instance == null) {
                VpnSessionCoordinator.event(
                    "start_gate_rejected",
                    generation,
                    "current_generation=${VpnSessionCoordinator.current()} session_state=missing source=mark_core_started reason=no_service",
                    Log.ERROR,
                )
                return false
            }
            return instance.confirmCoreStarted(generation)
        }

    }

    @Volatile
    private var sessionGeneration: Long = 0L
    @Volatile
    private var terminalStop = TerminalStop()
    private val tunOwner = TunDescriptorOwner()
    @Volatile
    private var activeSession: ActiveSession? = null
    @Volatile
    private var ownerDestroyed = false
    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status) { sessionGeneration }
    private val notification = ServiceNotification(status, service)
//    private var boxService: BoxService? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var receiverRegistered = false
    init {
        activeInstance = this
        activeInstances.add(this)
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    val generation = intent.getLongExtra(EXTRA_SESSION_GENERATION, 0L)
                    val source = intent.getStringExtra(EXTRA_STOP_SOURCE)?.let(VpnStopSource::fromWireValue)
                        ?: VpnStopSource.NOTIFICATION
                    receiveStop(generation, source, "close_broadcast")
                }

                Action.SERVICE_REPING -> {
                    rePingServers()
                }

                Action.SERVICE_CORE_STARTED -> {
                    val generation = intent.getLongExtra(EXTRA_SESSION_GENERATION, 0L)
                    serviceScope.launch {
                        confirmCoreStarted(generation)
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

    private fun receiveStop(generation: Long, source: VpnStopSource, dispatchSource: String) {
        if (source == VpnStopSource.REPLACEMENT) {
            val handled = VpnLifecycleIntentCoordinator.dispatchReplacementStop(generation) {
                val ownerGeneration = activeSession?.generation
                if (
                    (ownerGeneration != null && ownerGeneration >= generation) ||
                    (ownerGeneration == null && sessionGeneration >= generation && status.value != Status.Stopped)
                ) {
                    false
                } else {
                    stopService(generation, source)
                    true
                }
            }
            if (!handled) {
                VpnSessionCoordinator.stale(generation, "$dispatchSource/replacement")
            }
            return
        }
        if (generation > 0L && generation < VpnSessionCoordinator.current()) {
            VpnSessionCoordinator.stale(generation, dispatchSource)
            return
        }
        stopService(
            VpnSessionCoordinator.accept(generation, "$dispatchSource/${source.wireValue}"),
            source,
        )
    }

    private fun hasSessionOwnership(): Boolean =
        activeSession != null || tunOwner.hasOwnership() || status.value != Status.Stopped

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
            VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.STARTING_CORE)
            Log.d(TAG, "starting service")
            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, VpnSessionSnapshotCoordinator.current())
            }

            val selectedConfigPath = Settings.activeConfigPath
            if (selectedConfigPath.isBlank()) {
                stopAndAlert(generation, Alert.EmptyConfiguration)
                return
            }

            if (!CoreShutdownDispatcher.awaitSettled()) {
                VpnSessionCoordinator.event(
                    "core_start_failure",
                    generation,
                    "error=previous_core_shutdown_timeout",
                    Log.ERROR,
                )
                stopAndAlert(generation, Alert.StartService, "previous core shutdown is still running")
                return
            }
            if (!TunDescriptorOwner.awaitProcessSettled()) {
                VpnSessionCoordinator.event(
                    "core_start_failure",
                    generation,
                    "error=process_tun_owner_timeout",
                    Log.ERROR,
                )
                stopAndAlert(generation, Alert.StartService, "previous TUN owner is still closing")
                return
            }
            if (
                !VpnSessionCoordinator.isCurrent(generation) ||
                activeSession !== session ||
                !session.acceptsOperations()
            ) {
                VpnSessionCoordinator.stale(generation, "core_owner_acquire_after_wait")
                return
            }
            if (!CoreProcessOwnerCoordinator.tryAcquire(this, generation)) {
                VpnSessionCoordinator.event(
                    "core_start_failure",
                    generation,
                    "error=process_core_owner_conflict",
                    Log.ERROR,
                )
                stopAndAlert(generation, Alert.StartService, "another Android service still owns the core")
                return
            }

            activeProfileName = Settings.activeProfileName

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, VpnSessionSnapshotCoordinator.current())
                binder.broadcast {
                    it.onServiceResetLogs(listOf())
                }
            }

            DefaultNetworkMonitor.start(generation)
            Libbox.setMemoryLimit(!Settings.disableMemoryLimit)
            val startsCoreHere = Settings.startCoreAfterStartingService
            VpnSessionCoordinator.event("core_start_requested", generation, "owner=android starts_core=$startsCoreHere")
            val readiness = CoreNativeOperationCoordinator.exclusive {
                if (
                    !VpnSessionCoordinator.isCurrent(generation) ||
                    activeSession !== session ||
                    !session.acceptsOperations()
                ) {
                    CoreStartupGate.Result.Superseded
                } else if (!CoreShutdownDispatcher.awaitSettled()) {
                    CoreStartupGate.Result.Failed(
                        IllegalStateException("previous native close is still running"),
                    )
                } else {
                    try {
                        Mobile.setup(
                            SetupOptions().also {
                                it.basePath = Settings.baseDir
                                it.workingDir = Settings.workingDir
                                it.tempDir = Settings.tempDir
                                it.fixAndroidStack = com.zeon.zeon.bg.Bugs.fixAndroidStack
                                it.mode = 4L
                                it.listen = "127.0.0.1:${Settings.grpcServiceModePort}"
                                it.secret = ""
                                it.debug = Settings.debugMode
                            },
                            platformInterface,
                        )
                    } catch (error: Throwable) {
                        return@exclusive CoreStartupGate.Result.Failed(error)
                    }
                    if (
                        !VpnSessionCoordinator.isCurrent(generation) ||
                        activeSession !== session ||
                        !session.acceptsOperations()
                    ) {
                        CoreStartupGate.Result.Superseded
                    } else {
                        CoreStartupGate.awaitReady(
                            generation = generation,
                            startCore = if (startsCoreHere) {
                                { Mobile.start("", "") }
                            } else {
                                null
                            },
                            endpointReady = ::isCommandEndpointReady,
                        )
                    }
                }
            }
            when (readiness) {
                CoreStartupGate.Result.Ready -> {
                    session.markCommandEndpointReady()
                    VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.WAITING_TUN) {
                        it.copy(coreReady = true, commandEndpointReady = true)
                    }
                    VpnSessionCoordinator.event("command_endpoint_ready", generation)
                    VpnSessionCoordinator.event(
                        "start_gate_waiting",
                        generation,
                        "current_generation=${VpnSessionCoordinator.current()} session_state=starting source=command_endpoint reason=awaiting_mobile_start_tun_protect",
                    )
                    publishStatus(Status.CoreReady, generation, "command_endpoint_ready")
                }
                CoreStartupGate.Result.Superseded -> return
                is CoreStartupGate.Result.Failed -> {
                    VpnSessionCoordinator.event(
                        "core_start_failure",
                        generation,
                        "error=${readiness.error.javaClass.simpleName}",
                        Log.ERROR,
                    )
                    stopAndAlert(generation, Alert.StartService, readiness.error.message)
                    return
                }
                CoreStartupGate.Result.Timeout -> {
                    VpnSessionCoordinator.event("core_start_failure", generation, "error=command_endpoint_timeout", Log.ERROR)
                    stopAndAlert(generation, Alert.StartService, "command endpoint readiness timeout")
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
                notification.show(activeProfileName, VpnSessionSnapshotCoordinator.current())
            }
            if (startsCoreHere) {
                confirmCoreStarted(generation)
            }
        } catch (e: Exception) {
            if (!VpnSessionCoordinator.isCurrent(generation)) {
                VpnSessionCoordinator.event(
                    "stale_exception_ignored",
                    generation,
                    "current_generation=${VpnSessionCoordinator.current()} session_state=starting source=android_start_service reason=${e.javaClass.simpleName}",
                    Log.WARN,
                )
                return
            }
            stopAndAlert(generation, Alert.StartService, e.message)
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
        val currentStatus = status.value
        val reloadAllowed = Settings.startedByUser &&
            currentStatus != Status.Stopped &&
            currentStatus != Status.Stopping &&
            previousSession?.generation == sessionGeneration &&
            previousSession.acceptsOperations()
        val generation = VpnLifecycleIntentCoordinator.reserveReload(
            ownerToken = this,
            sessionGeneration = sessionGeneration,
            reloadAllowed = reloadAllowed,
            reason = "service_reload",
            ownerAcceptsReload = { !ownerDestroyed },
        )
        if (generation == null) {
            VpnSessionCoordinator.event(
                "service_reload_rejected",
                sessionGeneration,
                "status=${currentStatus?.name ?: "unknown"} started_by_user=${Settings.startedByUser}",
                Log.WARN,
            )
            return
        }
        if (previousSession != null) {
            closeSession(previousSession, "service_reload")
        }
        if (!tunOwner.awaitSettled()) {
            VpnSessionCoordinator.event(
                "service_reload_rejected",
                generation,
                "reason=previous_tun_close_timeout",
                Log.ERROR,
            )
            stopPreemptively(generation, VpnStopSource.INTERNAL)
            return
        }
        val session = ActiveSession(generation, platformInterface, tunOwner)
        val committed = VpnLifecycleIntentCoordinator.commitReload(this, generation) {
            if (ownerDestroyed) {
                false
            } else {
                sessionGeneration = generation
                terminalStop = TerminalStop()
                activeSession = session
                // These activation side effects are intentionally inside the
                // lifecycle lock. Destruction either runs after them and cleans
                // them up, or wins first and rejects the entire commit.
                notification.showStarting(Settings.activeProfileName, generation)
                publishStatus(Status.Starting, generation, "service_reload")
                session.scope.launch {
                    startService(generation)
                }
                true
            }
        }
        if (!committed) {
            session.scope.cancel("reload owner was destroyed or superseded")
            VpnSessionCoordinator.stale(generation, "service_reload_after_close")
            return
        }
        
//        boxService?.apply {
//            runCatching {
//                close()
//            }.onFailure {
//                writeLog("service: error when closing: $it")
//            }
//            Seq.destroyRef(refnum)
//        }
//        boxService = null

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

    private fun stopService(
        generation: Long = VpnSessionCoordinator.next("box_service_stop_internal"),
        source: VpnStopSource = VpnStopSource.INTERNAL,
    ) {
        if (generation > 0L && generation < VpnSessionCoordinator.current()) {
            VpnSessionCoordinator.stale(generation, "stop_service/${source.wireValue}")
            return
        }
        val closingSession = activeSession
        sessionGeneration = VpnSessionCoordinator.accept(generation, "stop_service")
        if (status.value == Status.Stopping) {
            val newestSource = newestStopSource(terminalStop.source, source)
            terminalStop = TerminalStop(sessionGeneration, newestSource)
            VpnSessionSnapshotCoordinator.requestStop(sessionGeneration, newestSource)
            VpnSessionSnapshotCoordinator.transition(sessionGeneration, VpnSessionPhase.STOPPING)
            return
        }
        terminalStop = TerminalStop(sessionGeneration, source)
        if (status.value == Status.Stopped && closingSession == null) {
            if (source.clearsExpectedRunning) Settings.startedByUser = false
            notification.close(sessionGeneration)
            status.value = Status.Stopped
            publishStatus(Status.Stopped, sessionGeneration, "stop_already_complete/${source.wireValue}")
            publishTerminalIfOwnersSettled(sessionGeneration, source)
            service.stopSelf()
            return
        }
        VpnSessionSnapshotCoordinator.requestStop(sessionGeneration, source)
        status.value = Status.Stopping
        VpnSessionSnapshotCoordinator.transition(sessionGeneration, VpnSessionPhase.STOPPING)
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        serviceScope.launch {
            if (closingSession != null) {
                closeSession(closingSession, "stop")
            }
            withContext(Dispatchers.Main) {
                val completedStop = terminalStop
                if (
                    completedStop.generation <= 0L ||
                    !VpnSessionCoordinator.isCurrent(completedStop.generation)
                ) {
                    VpnSessionCoordinator.stale(
                        completedStop.generation,
                        "stop_cleanup_after_newer_intent",
                    )
                    return@withContext
                }
                notification.close(completedStop.generation)
                if (completedStop.source.clearsExpectedRunning) Settings.startedByUser = false
                status.value = Status.Stopped
                publishStatus(Status.Stopped, completedStop.generation, "stop_complete/${completedStop.source.wireValue}")
                publishTerminalIfOwnersSettled(completedStop.generation, completedStop.source)
                service.stopSelf()
            }
        }
    }

    private suspend fun stopAndAlert(generation: Long, type: Alert, message: String? = null) {
        if (!VpnSessionCoordinator.isCurrent(generation) || activeSession?.generation != generation) {
            VpnSessionCoordinator.event(
                "stale_exception_ignored",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=${status.value?.name ?: "unknown"} source=stop_and_alert reason=${type.name}",
                Log.WARN,
            )
            return
        }
        Settings.startedByUser = false
        VpnSessionSnapshotCoordinator.failure(
            generation,
            type.name,
            "android_service",
            recoverable = true,
        )
        activeSession?.let { closeSession(it, "failed_start") }
        withContext(Dispatchers.Main) {
            if (!VpnSessionCoordinator.isCurrent(generation)) return@withContext
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            notification.close(generation)
            binder.broadcast { callback ->
                callback.onServiceAlert(type.ordinal, message)
            }
            status.value = Status.Stopped
        }
    }

    @Suppress("SameReturnValue")
    internal fun onStartCommand(intent: Intent?): Int {
        val requestedGeneration = intent?.getLongExtra(EXTRA_SESSION_GENERATION, 0L) ?: 0L
        if (requestedGeneration <= 0L) {
            VpnSessionCoordinator.event(
                "start_gate_rejected",
                requestedGeneration,
                "session_state=missing source=service_start_command reason=missing_generation",
                Log.ERROR,
            )
            service.stopSelf()
            return Service.START_NOT_STICKY
        }
        val generation = VpnSessionCoordinator.accept(requestedGeneration, "service_start_command")
        if (requestedGeneration > 0 && generation != requestedGeneration) {
            if (activeSession == null && status.value == Status.Stopped) {
                service.stopSelf()
            }
            return Service.START_NOT_STICKY
        }
        // A startForegroundService request must acknowledge Android's FGS
        // deadline even when ownership handoff requires asynchronous teardown.
        notification.showStarting(Settings.activeProfileName, generation)
        val otherOwners = activeInstances.filter {
            it !== this && it.hasSessionOwnership()
        }
        if (otherOwners.isNotEmpty()) {
            serviceScope.launch {
                otherOwners.forEach { owner ->
                    owner.closeForProcessReplacement(generation)
                }
                if (
                    !TunDescriptorOwner.awaitProcessSettled() ||
                    !CoreShutdownDispatcher.awaitSettled()
                ) {
                    stopPreemptively(generation, VpnStopSource.INTERNAL)
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    startAcceptedGeneration(generation)
                }
            }
            return Service.START_NOT_STICKY
        }
        startAcceptedGeneration(generation)
        return Service.START_NOT_STICKY
    }

    private fun startAcceptedGeneration(generation: Long) {
        if (!VpnSessionCoordinator.isCurrent(generation)) {
            if (activeSession == null && status.value == Status.Stopped) service.stopSelf()
            return
        }
        val previousSession = activeSession
        if (previousSession != null && previousSession.generation < generation) {
            VpnSessionCoordinator.event(
                "stale_owner_replacement_requested",
                generation,
                "previous_generation=${previousSession.generation} source=explicit_connect",
                Log.WARN,
            )
            serviceScope.launch {
                closeSession(previousSession, "explicit_connect_supersedes_stale_owner")
                if (!tunOwner.awaitSettled()) {
                    stopPreemptively(generation, VpnStopSource.INTERNAL)
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    beginExplicitSession(generation)
                }
            }
            return
        }
        if (previousSession == null && tunOwner.hasOwnership()) {
            serviceScope.launch {
                if (!tunOwner.awaitSettled()) {
                    stopPreemptively(generation, VpnStopSource.INTERNAL)
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    beginExplicitSession(generation)
                }
            }
            return
        }
        if (previousSession != null) {
            VpnSessionCoordinator.event(
                "core_already_started_conflict",
                generation,
                "status=${status.value} owner_generation=${previousSession?.generation ?: 0L}",
                Log.ERROR,
            )
            return
        }
        beginExplicitSession(generation)
    }

    private suspend fun closeForProcessReplacement(replacementGeneration: Long) {
        val session = activeSession
        if (session != null && session.generation < replacementGeneration) {
            closeSession(session, "process_service_owner_replacement")
        }
        withContext(Dispatchers.Main) {
            if (activeSession == null || activeSession?.generation != replacementGeneration) {
                notification.close(replacementGeneration)
                status.value = Status.Stopped
                if (receiverRegistered) {
                    runCatching { service.unregisterReceiver(receiver) }
                    receiverRegistered = false
                }
                service.stopSelf()
            }
        }
    }

    private fun beginExplicitSession(generation: Long): Boolean {
        val session = ActiveSession(generation, platformInterface, tunOwner)
        val committed = VpnLifecycleIntentCoordinator.commitStart(generation) {
            if (ownerDestroyed || activeSession != null) {
                false
            } else {
                sessionGeneration = generation
                terminalStop = TerminalStop()
                activeSession = session
                status.value = Status.Starting
                true
            }
        }
        if (!committed) {
            session.scope.cancel("explicit session owner was destroyed or superseded")
            VpnSessionCoordinator.event(
                "start_gate_rejected",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=${status.value?.name ?: "unknown"} source=service_start_command reason=terminal_or_newer_intent",
                Log.WARN,
            )
            if (activeSession == null && status.value == Status.Stopped) {
                service.stopSelf()
            }
            return false
        }
        VpnSessionSnapshotCoordinator.begin(generation, "connect")
        VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.STARTING_PLATFORM)
        VpnSessionCoordinator.event("vpn_session_start", generation, "owner=android")

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
        return true
    }

    fun onBind(intent: Intent): IBinder {
        return binder
    }

    fun onDestroy() {
        val destruction = VpnLifecycleIntentCoordinator.destroyOwner(this) {
            ownerDestroyed = true
            activeSession.also { activeSession = null }
        }
        val closingSession = destruction.detachedResource
        val abandonedReloadGeneration = destruction.pendingReloadGeneration
        val terminalSnapshot = VpnSessionSnapshotCoordinator.current()
        val terminalAlreadyPublished =
            terminalSnapshot.phase == VpnSessionPhase.DISCONNECTED || terminalSnapshot.phase == VpnSessionPhase.FAILED
        var terminalGeneration = 0L
        var terminalSource = VpnStopSource.NONE

        if (terminalStop.generation > 0L) {
            terminalGeneration = terminalStop.generation
            terminalSource = terminalStop.source
        } else if (
            terminalSnapshot.requestedAction == "stop" &&
            terminalSnapshot.generation == VpnSessionCoordinator.current()
        ) {
            terminalGeneration = terminalSnapshot.generation
            terminalSource = terminalSnapshot.stopSource
        } else if (!terminalAlreadyPublished) {
            val destroyedOwnerGeneration = maxOf(
                closingSession?.generation ?: 0L,
                abandonedReloadGeneration ?: 0L,
            )
            terminalGeneration = VpnLifecycleIntentCoordinator.reserveDestroyStopIfCurrent(
                expectedGeneration = destroyedOwnerGeneration,
                reason = "service_destroy",
            ) ?: 0L
            terminalSource = VpnStopSource.DESTROY
            if (terminalGeneration > 0L) {
                Settings.startedByUser = false
                sessionGeneration = terminalGeneration
                terminalStop = TerminalStop(terminalGeneration, terminalSource)
                VpnSessionSnapshotCoordinator.requestStop(terminalGeneration, terminalSource)
                VpnSessionSnapshotCoordinator.transition(terminalGeneration, VpnSessionPhase.STOPPING)
            }
        }

        status.value = Status.Stopped
        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        val notificationCleanupGeneration = maxOf(
            terminalGeneration,
            closingSession?.generation ?: 0L,
            sessionGeneration,
        )
        notification.close(notificationCleanupGeneration)
        binder.close()
        serviceScope.cancel()
        mainScope.cancel()
        if (activeInstance === this) {
            activeInstance = null
        }
        val finishDestroy = {
            activeInstances.remove(this)
            if (terminalGeneration > 0L && !terminalAlreadyPublished) {
                stopFallbackHandler.post {
                    publishTerminalIfOwnersSettled(terminalGeneration, terminalSource)
                }
            }
        }
        if (closingSession == null) {
            finishDestroy()
        } else {
            // Service.onDestroy runs on Android's main looper. Teardown keeps
            // ownership registered but must never synchronously block that looper.
            destructionScope.launch {
                closeSession(closingSession, "on_destroy")
                finishDestroy()
            }
        }
    }

    fun onRevoke() {
        stop(source = VpnStopSource.REVOKE)
    }

    internal fun currentSessionGeneration(): Long = sessionGeneration

    private data class TerminalStop(
        val generation: Long = 0L,
        val source: VpnStopSource = VpnStopSource.NONE,
    )

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
        val fd = tunOwner.open(generation, descriptor, validate)
        session.markTunReady(protectSucceeded = true)
        VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.VERIFYING) {
            it.copy(tunnelReady = true, protectSucceeded = true)
        }
        return fd
    }

    private suspend fun confirmCoreStarted(generation: Long): Boolean {
        val session = activeSession
        if (session == null || session.generation != generation) {
            VpnSessionCoordinator.event(
                "stale_completion_ignored",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=${status.value?.name ?: "unknown"} source=mark_core_started reason=session_mismatch",
                Log.WARN,
            )
            return false
        }

        val permissionGranted = service !is AndroidVpnService || AndroidVpnService.prepare(service) == null
        val result = VpnConnectedGate.evaluate(
            session.startEvidence(
                permissionGranted = permissionGranted,
                mobileStartSucceeded = true,
            ),
        )
        if (result is VpnConnectedGate.Result.Rejected) {
            val stale = !VpnSessionCoordinator.isCurrent(generation)
            VpnSessionCoordinator.event(
                if (stale) "stale_completion_ignored" else "start_gate_rejected",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=${status.value?.name ?: "unknown"} source=mark_core_started reason=${result.missing.joinToString("+")}",
                if (stale) Log.WARN else Log.ERROR,
            )
            if (!stale) {
                stopAndAlert(generation, Alert.StartService, "VPN startup readiness validation failed")
            }
            return false
        }

        val selectedOutbound = awaitSelectedOutbound(generation)
        VpnSessionSnapshotCoordinator.selectedOutbound(
            generation,
            selectedOutbound,
            if (selectedOutbound.startsWith(AUTO_BALANCER_TAG)) AUTO_BALANCER_TAG else "selector",
        )
        VpnSessionSnapshotCoordinator.transition(generation, VpnSessionPhase.VERIFYING) {
            it.copy(coreStarted = true)
        }

        if (!awaitValidatedVpn(generation)) {
            VpnSessionCoordinator.event(
                "start_gate_rejected",
                generation,
                "source=platform_vpn_validation reason=vpn_network_not_validated",
                Log.ERROR,
            )
            stopAndAlert(generation, Alert.StartService, "Android VPN network validation timeout")
            return false
        }
        val connectedSnapshot = VpnSessionSnapshotCoordinator.transition(
            generation,
            VpnSessionPhase.CONNECTED,
        ) {
            it.copy(platformVpnValidated = true)
        }
        if (!connectedSnapshot.provesConnected()) {
            VpnSessionCoordinator.event(
                "terminal_state_blocked",
                generation,
                "source=vpn_snapshot reason=connected_evidence_incomplete",
                Log.ERROR,
            )
            stopAndAlert(generation, Alert.StartService, "VPN session snapshot evidence incomplete")
            return false
        }

        VpnSessionCoordinator.event(
            "start_gate_completed",
            generation,
            "current_generation=${VpnSessionCoordinator.current()} session_state=started source=mark_core_started reason=all_required_evidence",
        )
        VpnSessionCoordinator.event("core_start_success", generation)
        if (!publishStatus(Status.Started, generation, "all_start_gates_confirmed")) {
            return false
        }
        withContext(Dispatchers.Main) {
            notification.show(activeProfileName, connectedSnapshot)
        }
        notification.start(generation) {
            activeSession === session && session.acceptsOperations()
        }
        return true
    }

    private suspend fun awaitValidatedVpn(generation: Long): Boolean {
        val connectivity = service.getSystemService(ConnectivityManager::class.java)
        repeat(50) {
            if (!VpnSessionCoordinator.isCurrent(generation)) return false
            val validated = connectivity.allNetworks.any { network ->
                val capabilities = connectivity.getNetworkCapabilities(network) ?: return@any false
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            }
            if (validated) return true
            delay(100L)
        }
        return false
    }

    private suspend fun awaitSelectedOutbound(generation: Long): String {
        repeat(20) {
            if (!VpnSessionCoordinator.isCurrent(generation)) return ""
            val outbound = runCatching {
                GrpcClientProvider.grpcClient.create(CoreClient::class)
                    .GetSystemInfo()
                    .executeBlocking(Empty())
                    .current_outbound
                    .trim()
            }.getOrDefault("")
            if (outbound.isNotBlank()) return outbound
            delay(100L)
        }
        return ""
    }

    private suspend fun closeSession(session: ActiveSession, reason: String) {
        // Detach the exact generation synchronously. The bounded async join may
        // finish later, but it can no longer observe/cancel a replacement job.
        val notificationListener = notification.detachSystemInfoListener(session.generation)
        session.close(
            reason = reason,
            closeCommandClientsAndListeners = {
                // Flutter owns gRPC client objects; Android owns the endpoint and
                // removes all native callbacks before stopping it.
                notification.awaitDetachedSystemInfoListener(notificationListener)
                DefaultNetworkMonitor.clearListener(session.generation)
            },
            stopCore = {
                if (CoreProcessOwnerCoordinator.owns(this, session.generation)) {
                    val completed = CoreShutdownDispatcher.close {
                        CoreNativeOperationCoordinator.exclusive {
                            try {
                                Mobile.close(4L)
                            } finally {
                                CoreProcessOwnerCoordinator.release(this, session.generation)
                            }
                        }
                    }
                    if (!completed) {
                        error("native core close timeout")
                    }
                }
            },
            closeCommandServer = { server ->
                server?.let {
                    runCatching { it.close() }
                    runCatching { Seq.destroyRef(it.refnum) }
                }
            },
            closePlatform = {
                DefaultNetworkMonitor.clearListener(session.generation)
            },
            clearNetwork = {
                if (activeSession === session) {
                    activeSession = null
                }
                DefaultNetworkMonitor.stop(session.generation)
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
