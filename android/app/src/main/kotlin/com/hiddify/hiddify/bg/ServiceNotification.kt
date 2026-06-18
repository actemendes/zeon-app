package com.hiddify.hiddify.bg

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
import com.hiddify.hiddify.Application
import com.hiddify.hiddify.MainActivity
import com.hiddify.hiddify.R
import com.hiddify.hiddify.Settings
import com.hiddify.hiddify.constant.Action
import com.hiddify.hiddify.constant.Status
//import com.hiddify.hiddify.utils.CommandClient
import com.hiddify.core.libbox.Libbox
import com.hiddify.hiddify.Application.Companion.notification
import com.hiddify.hiddify.utils.GrpcClientProvider
import com.squareup.wire.GrpcClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.isActive

import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.IOException
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
class ServiceNotification(private val status: MutableLiveData<Status>, private val service: Service) : BroadcastReceiver(){
    companion object {
        private const val notificationId = 1
        private const val notificationChannel = "service"
        var coreClient: CoreClient?=null
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

        fun checkPermission(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return true
            }
            return Application.notification.areNotificationsEnabled()
        }
    }
    val streamingCoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())


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
                                    Intent(Action.SERVICE_CLOSE).setPackage(
                                        Application.application.packageName
                                    ),
                                    flags
                            )
                            ).build()
                    )
                }
    }

    fun show(profileName: String, @StringRes contentTextId: Int) {
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
                .setContentText(service.getString(contentTextId)).build()
        )
    }


    suspend fun start() {
        if (Settings.dynamicNotification && checkPermission()) {
//            commandClient.connect()
            startListenSystemInfo()
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
        val content = "${Libbox.formatBytes(uplink)}/s ↑\t${Libbox.formatBytes(downlink)}/s ↓ \n${status.current_outbound}"
        val title = "${status.current_profile}"
        val outboundDisplay = formatOutboundDisplay(status.current_outbound)
        val displayContent = content.substringBeforeLast("\n", content) + "\n" + outboundDisplay
        Log.d("NotificationDisplay", "selected=${status.current_outbound} display=\"${outboundDisplay}\"")
        Application.notificationManager.notify(
                notificationId,
                notificationBuilder.setContentTitle(title).setContentText(displayContent).build()
        )
    }

    private fun formatOutboundDisplaySafe(rawOutbound: String): String {
        val autoPrefix = "\u0410\u0432\u0442\u043e\u0432\u044b\u0431\u043e\u0440 \u0441\u0435\u0440\u0432\u0435\u0440\u043e\u0432 \u00b7 "
        val choosing = autoPrefix + "\u0432\u044b\u0431\u0438\u0440\u0430\u0435\u0442\u0441\u044f \u0441\u0435\u0440\u0432\u0435\u0440..."
        val raw = rawOutbound.trim()
        if (raw.isBlank()) return choosing

        val normalized = raw.lowercase()
        if (normalized == "balance") {
            return choosing
        }

        val arrowParts = raw.split("\u2192", "->", limit = 2).map { it.trim() }
        if (arrowParts.isNotEmpty() && arrowParts[0].lowercase() == "balance") {
            val real = arrowParts.getOrNull(1).orEmpty()
            return if (real.isBlank() || real.lowercase() == "balance") choosing else autoPrefix + real
        }

        return raw
    }

    private fun formatOutboundDisplay(rawOutbound: String): String {
        return formatOutboundDisplaySafe(rawOutbound)
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON -> {
                startListenSystemInfo()
            }

            Intent.ACTION_SCREEN_OFF -> {
                stopListenSystemInfo()
            }
        }
    }

    fun close() {
        stopListenSystemInfo()
        ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (receiverRegistered) {
            service.unregisterReceiver(this)
            receiverRegistered = false
        }
    }

    private var streamingJob: Job? = null

    fun startListenSystemInfo() {
        // Cancel any previous stream if still running
        Log.d("notification","startListenSystemInfo")
        streamingJob?.cancel()

        streamingJob = streamingCoroutineScope.launch(Dispatchers.IO) {
            Log.d("notification", "startListenSystemInfo-launch")

            val coreClient = GrpcClientProvider.grpcClient.create(CoreClient::class)

            try {
                var previous = coreClient.GetSystemInfo().executeBlocking(Empty())

                while (isActive) {
                    delay(1_000) // ✅ coroutine-friendly
                    val current = coreClient.GetSystemInfo().executeBlocking(Empty())
                    updateStatus(previous,current)
                    previous = current
                }
            } catch (e: CancellationException) {
                // coroutine cancelled normally
                Log.d("notification", "SystemInfo polling cancelled")
                notification.cancel(notificationId)
            } catch (e: Exception) {
                Log.e("notification", "SystemInfo polling failed", e)
                notification.cancel(notificationId)
            }
        }
    }
    fun stopListenSystemInfo(){
        try {
            streamingJob?.cancel()
        }catch (e: Exception){
            Log.d("notification", "Exception ${e}")
        }
    }
}
