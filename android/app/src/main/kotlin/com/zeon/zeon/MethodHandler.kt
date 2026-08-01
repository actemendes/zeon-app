package com.zeon.zeon

import android.util.Log
import com.zeon.zeon.bg.BoxService
//import com.zeon.zeon.bg.BoxService.Companion.workingDir
import com.zeon.zeon.constant.Status
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

import com.hiddify.core.libbox.Libbox
import com.hiddify.core.mobile.Mobile
import com.hiddify.core.mobile.SetupOptions
import com.zeon.zeon.bg.Bugs
import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.bg.StartPermissionRequestCoordinator
import com.zeon.zeon.bg.VpnSessionSnapshotCoordinator
import com.zeon.zeon.bg.VpnStopSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MethodHandler(private val scope: CoroutineScope) : FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    companion object {
        const val TAG = "A/MethodHandler"
        const val channelName = "com.zeon.app/method"

        enum class Trigger(val method: String) {
            Setup("setup"),
            PrepareVpn("prepare_vpn"),
            Start("start"),
            Stop("stop"),
            Restart("restart"),
            SetSessionGeneration("set_session_generation"),
            MarkCoreStarted("mark_core_started"),
            GetVpnSessionSnapshot("get_vpn_session_snapshot"),
            AddGrpcClientPublicKey("add_grpc_client_public_key"),
            GetGrpcServerPublicKey("get_grpc_server_public_key"),

        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            channelName,
        )
        channel!!.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            Trigger.AddGrpcClientPublicKey.method -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        val clientPub = args["clientPublicKey"] as ByteArray
//                        Mobile.addGrpcClientPublicKey(clientPub)
                        Settings.grpcFlutterPublicKey = clientPub
                        success("")

                    }
                }
            }

            Trigger.GetGrpcServerPublicKey.method -> {
                scope.launch {
                    result.runCatching {
                        result.success(Mobile.getServerPublicKey())
                    }
                }
            }

            Trigger.Setup.method -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        Settings.baseDir = args["baseDir"] as String
                        Settings.workingDir = args["workingDir"] as String
                        Settings.tempDir = args["tempDir"] as String
                        Settings.debugMode = args["debug"] as Boolean? ?: false
                        val mode = args["mode"] as Int
                        val grpcPort = args["grpcPort"] as Int
                        Log.d("debugmode","${Settings.debugMode}")
                        runCatching {
                            Mobile.setup(
                                SetupOptions().also {
                                    it.basePath = Settings.baseDir
                                    it.workingDir = Settings.workingDir
                                    it.tempDir = Settings.tempDir
                                    it.fixAndroidStack = Bugs.fixAndroidStack
                                    it.mode=mode.toLong()
                                    it.listen= "127.0.0.1:" + grpcPort
                                    it.secret=""
                                    it.debug = Settings.debugMode
                                },null)

//                            Libbox.setup(Settings.baseDir, Settings.workingDir, Settings.tempDir, false)
                            Libbox.redirectStderr(File(Settings.workingDir, "stderr2.log").path)

                            success("")
                        }.onFailure {
                            error(it)
                        }

                    }
                }
            }


            Trigger.PrepareVpn.method -> {
                scope.launch {
                    try {
                        val args = call.arguments as Map<*, *>
                        Settings.activeConfigPath = args["path"] as String? ?: ""
                        Settings.activeProfileName = args["name"] as String? ?: ""
                        Settings.grpcServiceModePort = args["grpcPort"] as Int
                        Settings.disableMemoryLimit = args["disableMemoryLimit"] as Boolean? ?: false
                        val generation = (args["generation"] as Number?)?.toLong() ?: 0L
                        val acceptedGeneration = VpnSessionCoordinator.accept(generation, "prepare_vpn")
                        if (generation <= 0 || acceptedGeneration != generation) {
                            VpnSessionCoordinator.event(
                                "permission_result_ignored_stale",
                                generation,
                                "current_generation=$acceptedGeneration session_state=permission source=method_handler reason=invalid_generation",
                            )
                            result.error("vpn_operation_stale", "VPN permission result belongs to a stale session", null)
                            return@launch
                        }

                        MainActivity.instance.prepareVpn(generation) { outcome ->
                            when (outcome) {
                                StartPermissionRequestCoordinator.Outcome.Granted -> result.success(true)
                                StartPermissionRequestCoordinator.Outcome.NotificationDenied,
                                StartPermissionRequestCoordinator.Outcome.VpnDenied,
                                -> result.success(false)
                                StartPermissionRequestCoordinator.Outcome.Stale -> result.error(
                                    "vpn_operation_stale",
                                    "VPN permission result belongs to a stale session",
                                    null,
                                )
                            }
                        }
                    } catch (e: Exception) {
                        result.error("prepare_vpn_failed", e.message, null)
                    }
                }
            }

            Trigger.Start.method -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        Settings.activeConfigPath = args["path"] as String? ?: ""
                        Settings.activeProfileName = args["name"] as String? ?: ""
                        Settings.debugMode = args["debug"] as Boolean? ?: false
                        Settings.grpcServiceModePort = args["grpcPort"] as Int
                        val generation = (args["generation"] as Number?)?.toLong() ?: 0L

                        val mainActivity = MainActivity.instance
//                        val started = mainActivity.serviceStatus.value == Status.Started
//                        if (started) {
//                            Log.w(TAG, "service is already running")
//                            return@launch success(true)
//                        }
                        Settings.startCoreAfterStartingService = false

                        mainActivity.startService(generation)
                        success(generation)
                    }
                }
            }

            Trigger.Stop.method -> {
                scope.launch {
                    result.runCatching {
                        val mainActivity = MainActivity.instance
                        val started = mainActivity.serviceStatus.value == Status.Started
                        if (!started) {
                            Log.w(TAG, "service is not running")
                            //    return@launch success(true)
                        }
                        val args = call.arguments as? Map<*, *>
                        val generation = (args?.get("generation") as Number?)?.toLong() ?: 0L
                        val preemptive = args?.get("preemptive") as? Boolean ?: false
                        val currentGeneration = VpnSessionCoordinator.current()
                        if (preemptive) {
                            // This method call is the newest explicit user Stop
                            // to reach Android. Rebase it above any tile/service
                            // generation Dart has not observed yet, then stop
                            // the current owner atomically.
                            val acceptedGeneration = VpnSessionCoordinator.nextAfter(
                                generation,
                                "flutter_stop_preemptive_rebase",
                            )
                            BoxService.stop(acceptedGeneration, VpnStopSource.FLUTTER)
                            success(acceptedGeneration)
                        } else if (generation > 0L && generation < currentGeneration) {
                            VpnSessionCoordinator.stale(generation, "flutter_stop")
                            success(currentGeneration)
                        } else {
                            val acceptedGeneration = VpnSessionCoordinator.accept(generation, "flutter_stop")
                            BoxService.stop(acceptedGeneration, VpnStopSource.FLUTTER)
                            success(acceptedGeneration)
                        }
                    }
                }
            }

            Trigger.SetSessionGeneration.method -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as? Map<*, *>
                        val generation = (args?.get("generation") as Number?)?.toLong() ?: 0L
                        success(VpnSessionCoordinator.accept(generation, "flutter_generation_update"))
                    }
                }
            }

            Trigger.MarkCoreStarted.method -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as? Map<*, *>
                        val generation = (args?.get("generation") as Number?)?.toLong() ?: 0L
                        if (!VpnSessionCoordinator.isCurrent(generation)) {
                            VpnSessionCoordinator.stale(generation, "flutter_mark_core_started")
                            result.error("vpn_operation_stale", "VPN core completion belongs to a stale session", null)
                            return@runCatching
                        }
                        val confirmed = withContext(Dispatchers.IO) {
                            BoxService.markCoreStarted(generation)
                        }
                        if (!confirmed) {
                            result.error(
                                "vpn_start_gate_rejected",
                                "VPN startup readiness validation failed",
                                null,
                            )
                            return@runCatching
                        }
                        success(generation)
                    }
                }
            }

            Trigger.GetVpnSessionSnapshot.method -> {
                result.success(VpnSessionSnapshotCoordinator.current().toEvent())
            }

//            Trigger.Restart.method -> {
//                scope.launch(Dispatchers.IO) {
//                    result.runCatching {
//                        val args = call.arguments as Map<*, *>
//                        Settings.activeConfigPath = args["path"] as String? ?: ""
//                        Settings.activeProfileName = args["name"] as String? ?: ""
//                        val mainActivity = MainActivity.instance
//                        val started = mainActivity.serviceStatus.value == Status.Started
//                        if (!started) return@launch success(true)
//                        val restart = Settings.rebuildServiceMode()
//                        if (restart) {
//                            mainActivity.reconnect()
//                            BoxService.stop()
//                            delay(1000L)
//                            mainActivity.startService()
//                            return@launch success(true)
//                        }
//                        runCatching {
//                            Libbox.newStandaloneCommandClient().serviceReload()
//                            success(true)
//                        }.onFailure {
//                            error(it)
//                        }
//                    }
//                }
//            }

            else -> result.notImplemented()
        }
    }

}
