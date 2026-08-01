package com.zeon.zeon.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import androidx.annotation.StringRes
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.MutableLiveData
import com.hiddify.core.api.v2.config.Protocol
import com.hiddify.core.api.v2.hcommon.Empty
import com.hiddify.core.api.v2.hcore.CoreClient
import com.hiddify.core.api.v2.hcore.SystemInfo
import com.hiddify.core.api.v2.hello.HelloClient
import com.hiddify.core.api.v2.hello.HelloRequest
import com.zeon.zeon.Application
import com.zeon.zeon.MainActivity
import com.zeon.zeon.R
import com.zeon.zeon.Settings
import com.zeon.zeon.constant.Action
import com.zeon.zeon.constant.Status
//import com.zeon.zeon.utils.CommandClient
import com.hiddify.core.libbox.Libbox
import com.zeon.zeon.Application.Companion.notification
import com.zeon.zeon.utils.GrpcClientProvider
import com.squareup.wire.GrpcClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.withTimeoutOrNull
class ServiceNotification(private val status: MutableLiveData<Status>, private val service: Service) : BroadcastReceiver(){
    data class DetachedSystemInfoListener internal constructor(
        val generation: Long,
        internal val job: Job?,
    )

    companion object {
        private data class ForegroundOwner(
            val notification: ServiceNotification,
            val generation: Long,
        )

        private const val notificationId = 1
        private const val notificationChannel = "service"
        private const val AUTO_BALANCER_TAG = "balance"
        private val foregroundLock = Any()
        private var foregroundOwner: ForegroundOwner? = null
        var coreClient: CoreClient?=null
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)

        internal fun stopIntent(context: Context): Intent =
            Intent(context, VpnNotificationActionReceiver::class.java)
                .setAction(Action.SERVICE_CLOSE_REQUEST)

        fun checkPermission(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return true
            }
            return Application.notification.areNotificationsEnabled()
        }
    }
    val streamingCoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val notificationLock = Any()
    @Volatile
    private var notificationGeneration = 0L


//
//    private val commandClient =
//            CommandClient(GlobalScope, CommandClient.ConnectionType.Status, this)
    private var receiverRegistered = false


    private val notificationBuilder by lazy {
        NotificationCompat.Builder(service, notificationChannel)
                .setShowWhen(false)
                .setOngoing(true)
                .setContentTitle(service.getString(R.string.app_name))
                .setOnlyAlertOnce(true)
                .setSmallIcon(R.drawable.ic_stat_logo)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setContentIntent(
                        PendingIntent.getActivity(
                                service,
                                0,
                                Intent(
                                        service,
                                        MainActivity::class.java
                                ).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                                flags
                        )
                )
                .setPriority(NotificationCompat.PRIORITY_LOW).apply {
                    addAction(
                            NotificationCompat.Action.Builder(
                                    0, service.getText(R.string.stop), PendingIntent.getBroadcast(
                                    service,
                                    0,
                                    stopIntent(service),
                                    flags
                            )
                            ).build()
                    )
                    addAction(
                            NotificationCompat.Action.Builder(
                                    0, service.getText(R.string.re_ping), PendingIntent.getBroadcast(
                                    service,
                                    1,
                                    Intent(Action.SERVICE_REPING).setPackage(
                                        Application.application.packageName
                                    ),
                                    flags
                            )
                            ).build()
                    )
                }
    }

    fun show(profileName: String, snapshot: VpnSessionSnapshot) {
        synchronized(foregroundLock) {
            val processOwner = foregroundOwner
            if (processOwner != null && snapshot.generation < processOwner.generation) return
            synchronized(notificationLock) {
                if (snapshot.generation < notificationGeneration) return
                notificationGeneration = snapshot.generation
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Application.notification.createNotificationChannel(
                        NotificationChannel(
                            notificationChannel,
                            service.getString(R.string.notification_channel_connection),
                            NotificationManager.IMPORTANCE_LOW,
                        ).apply {
                            description = service.getString(R.string.notification_channel_connection_description)
                        }
                    )
                }
                service.startForeground(
                    notificationId, notificationBuilder
                        .setContentTitle(profileName.takeIf { it.isNotBlank() } ?: service.getString(R.string.app_name))
                        .setContentText(
                            service.getString(
                                if (snapshot.provesConnected()) R.string.status_started else R.string.status_starting,
                            ),
                        ).build()
                )
                foregroundOwner = ForegroundOwner(this, snapshot.generation)
            }
        }
    }

    fun showStarting(profileName: String, generation: Long) {
        val current = VpnSessionSnapshotCoordinator.current()
        show(
            profileName,
            current.copy(
                generation = generation,
                phase = VpnSessionPhase.STARTING_PLATFORM,
                coreReady = false,
                coreStarted = false,
                commandEndpointReady = false,
                tunnelReady = false,
                protectSucceeded = false,
                platformVpnValidated = false,
            ),
        )
    }


    suspend fun start(generation: Long, sessionAcceptsOperations: () -> Boolean) {
        awaitDetachedSystemInfoListener(
            detachSystemInfoListener(maximumGeneration = generation),
        )
        if (!VpnSessionCoordinator.isCurrent(generation)) return
        val installed = synchronized(streamLock) {
            if (activeGeneration > generation) {
                false
            } else {
                activeGeneration = generation
                activeSessionAcceptsOperations = sessionAcceptsOperations
                true
            }
        }
        if (!installed) return
        if (Settings.dynamicNotification && checkPermission()) {
//            commandClient.connect()
            startListenSystemInfo(generation, sessionAcceptsOperations)
            withContext(Dispatchers.Main) {
                registerReceiver()
            }
        }
    }

    private fun registerReceiver() {
        service.registerReceiver(this, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        })
        receiverRegistered = true
    }

    fun updateStatus(previous:SystemInfo,status: SystemInfo) {
        val uplink=status.uplink_total - previous.uplink_total
        val downlink=status.downlink_total - previous.downlink_total
        val generation = activeGeneration
        val snapshot = VpnSessionSnapshotCoordinator.selectedOutbound(
            generation,
            status.current_outbound,
            if (status.current_outbound.startsWith(AUTO_BALANCER_TAG)) AUTO_BALANCER_TAG else "selector",
        )
        if (!snapshot.provesConnected()) return
        val currentOutbound = presentOutboundForNotification(snapshot.selectedOutboundLabel)
        val content = "${Libbox.formatBytes(uplink)}/s \u2191\t${Libbox.formatBytes(downlink)}/s \u2193 \n$currentOutbound"
        val title = "${status.current_profile}"
        Application.notificationManager.notify(
                notificationId,
                notificationBuilder.setContentTitle(title).setContentText(content).build()
        )
    }

    private fun presentOutboundForNotification(outbound: String): String {
        val normalized = outbound.trim()
        val match = Regex("^$AUTO_BALANCER_TAG\\s*(?:->|>|\\u2192|\\u2022|в†’|вЂў)\\s*(.+?)\\s*$", RegexOption.IGNORE_CASE)
            .find(normalized)
        if (match != null) {
            val realOutbound = presentServerNameForNotification(match.groupValues[1])
            if (realOutbound.isNotBlank()) {
                return "${service.getString(R.string.auto_selection)} \u2022 $realOutbound"
            }
            return service.getString(R.string.auto_selection)
        }
        if (Regex("^$AUTO_BALANCER_TAG(?:\\s|$).*", RegexOption.IGNORE_CASE).matches(normalized)) {
            return service.getString(R.string.auto_selection)
        }
        return presentServerNameForNotification(normalized)
    }

    private fun presentServerNameForNotification(outbound: String): String {
        return outbound
            .substringBefore("\u00A7")
            .substringBefore("В§")
            .trim()
    }

    private fun presentOutbound(outbound: String): String {
        val normalized = outbound.trim()
        val match = Regex("^$AUTO_BALANCER_TAG\\s*(?:->|>|→|•)\\s*(.+?)\\s*$", RegexOption.IGNORE_CASE)
            .find(normalized)
        if (match != null) {
            val realOutbound = presentServerName(match.groupValues[1])
            if (realOutbound.isNotBlank()) {
                return "${service.getString(R.string.auto_selection)} • $realOutbound"
            }
            return service.getString(R.string.auto_selection)
        }
        if (Regex("^$AUTO_BALANCER_TAG(?:\\s|$).*", RegexOption.IGNORE_CASE).matches(normalized)) {
            return service.getString(R.string.auto_selection)
        }
        return presentServerName(normalized)
    }

    private fun presentServerName(outbound: String): String {
        return outbound
            .substringBefore("§")
            .trim()
    }
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON -> {
                val generation = activeGeneration
                val acceptsOperations = activeSessionAcceptsOperations
                if (generation > 0L && acceptsOperations != null) {
                    startListenSystemInfo(generation, acceptsOperations)
                }
            }

            Intent.ACTION_SCREEN_OFF -> {
                stopListenSystemInfo()
            }
        }
    }

    fun close(maximumGeneration: Long? = null): Boolean {
        synchronized(foregroundLock) {
            synchronized(notificationLock) {
                val processOwner = foregroundOwner
                if (
                    maximumGeneration != null &&
                    (notificationGeneration > maximumGeneration ||
                        (processOwner?.notification === this && processOwner.generation > maximumGeneration))
                ) {
                    return false
                }
                notificationGeneration = 0L
                detachSystemInfoListener(maximumGeneration = maximumGeneration)?.job?.cancel()
                if (processOwner?.notification === this) {
                    foregroundOwner = null
                    ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_REMOVE)
                } else {
                    // The notification ID is process-wide. Detach this stale
                    // service without removing the newer owner's notification.
                    ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_DETACH)
                }
                if (receiverRegistered) {
                    service.unregisterReceiver(this)
                    receiverRegistered = false
                }
                return true
            }
        }
    }

    private val streamLock = Any()
    private var streamingJob: Job? = null
    @Volatile
    private var activeGeneration: Long = 0L
    @Volatile
    private var activeSessionAcceptsOperations: (() -> Boolean)? = null

    private fun startListenSystemInfo(generation: Long, sessionAcceptsOperations: () -> Boolean) {
        Log.d("notification","startListenSystemInfo")
        val job = streamingCoroutineScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            Log.d("notification", "startListenSystemInfo-launch")

            val coreClient = GrpcClientProvider.grpcClient.create(CoreClient::class)
            // Keep one HTTP/2 call alive. Reissuing a unary call every second
            // made OkHttp host canonicalization hot enough to trigger an ART
            // JIT crash on affected Android builds.
            val systemInfoStream = coreClient.GetSystemInfoStream()

            try {
                if (!isPollingCurrent(generation, sessionAcceptsOperations, "initial")) return@launch
                val (requests, responses) = systemInfoStream.executeIn(this)
                requests.send(Empty())
                requests.close()

                var previous: SystemInfo? = null
                for (current in responses) {
                    if (!isPollingCurrent(generation, sessionAcceptsOperations, "result")) break
                    previous?.let { updateStatus(it, current) }
                    previous = current
                }
            } catch (e: CancellationException) {
                // coroutine cancelled normally
                Log.d("notification", "SystemInfo polling cancelled")
            } catch (e: Exception) {
                Log.e("notification", "SystemInfo polling failed", e)
                if (generation == activeGeneration) {
                    notification.cancel(notificationId)
                }
            } finally {
                systemInfoStream.cancel()
            }
        }
        val previous = synchronized(streamLock) {
            if (activeGeneration != generation) {
                null
            } else {
                streamingJob.also { streamingJob = job }
            }
        }
        if (generation != activeGeneration) {
            job.cancel()
            return
        }
        previous?.cancel()
        job.start()
    }
    private fun isPollingCurrent(
        generation: Long,
        sessionAcceptsOperations: () -> Boolean,
        source: String,
    ): Boolean {
        val current = generation == activeGeneration &&
            VpnSessionCoordinator.isCurrent(generation) &&
            sessionAcceptsOperations()
        if (!current) {
            VpnSessionCoordinator.event(
                "stale_completion_ignored",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=notification source=system_info_$source reason=session_closed",
                Log.WARN,
            )
        }
        return current
    }

    fun detachSystemInfoListener(
        expectedGeneration: Long? = null,
        maximumGeneration: Long? = null,
    ): DetachedSystemInfoListener? = synchronized(streamLock) {
        if (expectedGeneration != null && activeGeneration != expectedGeneration) {
            return@synchronized null
        }
        if (maximumGeneration != null && activeGeneration > maximumGeneration) {
            return@synchronized null
        }
        val generation = activeGeneration
        val job = streamingJob
        activeGeneration = 0L
        activeSessionAcceptsOperations = null
        streamingJob = null
        job?.cancel()
        DetachedSystemInfoListener(generation, job)
    }

    suspend fun awaitDetachedSystemInfoListener(handle: DetachedSystemInfoListener?) {
        val job = handle?.job
        if (job != null) {
            val joined = withTimeoutOrNull(750L) {
                job.join()
                true
            } ?: false
            if (!joined) {
                VpnSessionCoordinator.event(
                    "terminal_failure",
                    handle.generation,
                    "phase=session_close resource=notification_listener error=timeout",
                    Log.ERROR,
                )
            }
        }
    }

    suspend fun stopListenSystemInfoAndJoin() {
        awaitDetachedSystemInfoListener(detachSystemInfoListener())
    }

    fun stopListenSystemInfo(){
        try {
            synchronized(streamLock) { streamingJob }?.cancel()
        }catch (e: Exception){
            Log.d("notification", "Exception ${e}")
        }
    }

    internal fun installSystemInfoGenerationForTesting(generation: Long) {
        synchronized(streamLock) {
            activeGeneration = generation
            activeSessionAcceptsOperations = { true }
            streamingJob = null
        }
    }

    internal fun activeSystemInfoGenerationForTesting(): Long = activeGeneration
}
