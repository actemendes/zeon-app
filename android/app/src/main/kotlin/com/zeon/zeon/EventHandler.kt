package com.zeon.zeon

import android.util.Log
import androidx.lifecycle.Observer
import com.zeon.zeon.constant.Alert
import com.zeon.zeon.constant.Status
import com.zeon.zeon.bg.VpnSessionSnapshot
import com.zeon.zeon.bg.VpnSessionSnapshotCoordinator
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.JSONMethodCodec

class EventHandler : FlutterPlugin {

    companion object {
        const val TAG = "A/EventHandler"
        const val SERVICE_STATUS = "com.zeon.app/service.status"
        const val SERVICE_ALERTS = "com.zeon.app/service.alerts"
        const val SERVICE_SNAPSHOT = "com.zeon.app/service.snapshot"
    }

    private var statusChannel: EventChannel? = null
    private var alertsChannel: EventChannel? = null
    private var snapshotChannel: EventChannel? = null

    private var statusObserver: Observer<Status>? = null
    private var alertsObserver: Observer<ServiceEvent?>? = null
    private var snapshotObserver: Observer<VpnSessionSnapshot>? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        statusChannel = EventChannel(flutterPluginBinding.binaryMessenger, SERVICE_STATUS, JSONMethodCodec.INSTANCE)
        alertsChannel = EventChannel(flutterPluginBinding.binaryMessenger, SERVICE_ALERTS, JSONMethodCodec.INSTANCE)
        snapshotChannel = EventChannel(flutterPluginBinding.binaryMessenger, SERVICE_SNAPSHOT, JSONMethodCodec.INSTANCE)

        statusChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statusObserver = Observer {
                    Log.d(TAG, "new status: $it")
                    val map = listOf(
                        Pair("status", it.name),
                        Pair("generation", MainActivity.instance.serviceGeneration.value ?: 0L),
                    )
                        .toMap()
                    events?.success(map)
                }
                MainActivity.instance.serviceStatus.observeForever(statusObserver!!)
            }

            override fun onCancel(arguments: Any?) {
                if (statusObserver != null)
                    MainActivity.instance.serviceStatus.removeObserver(statusObserver!!)
            }
        })

        alertsChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                alertsObserver = Observer {
                    if (it == null) return@Observer
                    Log.d(TAG, "new alert: $it")
                    val map = listOf(
                        Pair("status", it.status.name),
                        Pair("alert", it.alert?.name),
                        Pair("message", it.message),
                        Pair("generation", it.generation),
                    )
                        .mapNotNull { p -> p.second?.let { Pair(p.first, p.second) } }
                        .toMap()
                    events?.success(map)
                }
                MainActivity.instance.serviceAlerts.observeForever(alertsObserver!!)
            }

            override fun onCancel(arguments: Any?) {
                if (alertsObserver != null)
                    MainActivity.instance.serviceAlerts.removeObserver(alertsObserver!!)
            }
        })

        snapshotChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                snapshotObserver?.let(VpnSessionSnapshotCoordinator.snapshots::removeObserver)
                snapshotObserver = Observer { snapshot ->
                    events?.success(snapshot.toEvent())
                }
                VpnSessionSnapshotCoordinator.snapshots.observeForever(snapshotObserver!!)
            }

            override fun onCancel(arguments: Any?) {
                snapshotObserver?.let(VpnSessionSnapshotCoordinator.snapshots::removeObserver)
                snapshotObserver = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (statusObserver != null)
            MainActivity.instance.serviceStatus.removeObserver(statusObserver!!)
        statusChannel?.setStreamHandler(null)
        if (alertsObserver != null)
            MainActivity.instance.serviceAlerts.removeObserver(alertsObserver!!)
        alertsChannel?.setStreamHandler(null)
        snapshotObserver?.let(VpnSessionSnapshotCoordinator.snapshots::removeObserver)
        snapshotObserver = null
        snapshotChannel?.setStreamHandler(null)
    }
}

data class ServiceEvent(
    val status: Status,
    val alert: Alert? = null,
    val message: String? = null,
    val generation: Long = 0L,
)
