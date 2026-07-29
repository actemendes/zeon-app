package com.zeon.zeon.bg
import android.util.Log

import com.zeon.zeon.Settings
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import com.hiddify.core.libbox.Notification
import com.zeon.zeon.constant.PerAppProxyMode
import com.zeon.zeon.ktx.toIpPrefix
import com.hiddify.core.libbox.TunOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.net.DatagramSocket
import java.net.InetSocketAddress

class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "A/VPNService"
    }

    private val service = BoxService(this, this)

    override fun onCreate() {
        super.onCreate()
        VpnSessionCoordinator.event(
            "vpn_service_create",
            VpnSessionCoordinator.current(),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) =
        service.onStartCommand(intent)

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind(intent)
    }

    override fun onDestroy() {
        VpnSessionCoordinator.event(
            "vpn_service_destroy",
            service.currentSessionGeneration(),
        )
        try {
            service.onDestroy()
        } finally {
            super.onDestroy()
        }
    }

    override fun onRevoke() {
        runBlocking {
            withContext(Dispatchers.Main) {
                service.onRevoke()
            }
        }
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        val generation = service.currentSessionGeneration()
        val protected = protect(fd)
        VpnSessionCoordinator.event(
            "protect_result",
            generation,
            "source=core_socket success=$protected",
            if (protected) Log.INFO else Log.ERROR,
        )
        if (!protected) {
            error("android: VpnService.protect failed for core socket")
        }
    }

    var systemProxyAvailable = false
    var systemProxyEnabled = false
    fun addIncludePackage(builder: Builder, packageName: String) {
        if (packageName == this.packageName) { 
            return
        }
        try {     
            builder.addAllowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    fun addExcludePackage(builder: Builder, packageName: String) {
        try {     
            builder.addDisallowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    override fun openTun(options: TunOptions): Int {
        val generation = service.currentSessionGeneration()
        VpnSessionCoordinator.event("tun_open_requested", generation)
        if (!VpnSessionCoordinator.isCurrent(generation)) {
            VpnSessionCoordinator.event(
                "stale_exception_ignored",
                generation,
                "current_generation=${VpnSessionCoordinator.current()} session_state=tun source=open_tun reason=pre_establish_generation_check",
                Log.WARN,
            )
            error("stale VPN operation")
        }
        var hasPermission = false
        for (i in 0 until 20) {
            if (prepare(this) != null) {
                Log.w("VPN", "android: missing vpn permission")
            } else {
                hasPermission = true
                break
            }
            Thread.sleep(50)
        }

        if (!hasPermission) {
             error("android: missing vpn permission")
    }
//        service.fileDescriptor?.close()

        val builder = Builder()
            .setSession("zeon")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddress = options.inet4RouteAddress
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        builder.addRoute(inet4RouteAddress.next().toIpPrefix())
                    }
                } else {
                    builder.addRoute("0.0.0.0", 0)
                }

                val inet6RouteAddress = options.inet6RouteAddress
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        builder.addRoute(inet6RouteAddress.next().toIpPrefix())
                    }
                } else {
                    builder.addRoute("::", 0)
                }

                val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                while (inet4RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet4RouteExcludeAddress.next().toIpPrefix())
                }

                val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet6RouteExcludeAddress.next().toIpPrefix())
                }
            } else {
                val inet4RouteAddress = options.inet4RouteRange
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        val address = inet4RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }

                val inet6RouteAddress = options.inet6RouteRange
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        val address = inet6RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }
            }

            if (Settings.perAppProxyEnabled) {
                if (Settings.hasPerAppProxyConflict) {
                    Log.e(TAG, "Per-app proxy include/exclude lists are both populated; applying only active mode: ${Settings.perAppProxyMode}")
                }
                val appList = Settings.perAppProxyList
                if (Settings.perAppProxyMode == PerAppProxyMode.INCLUDE) {
                    appList.forEach {
                        addIncludePackage(builder,it)
                    }
//                    addIncludePackage(builder,packageName)
                } else {
                    appList.forEach {
                        addExcludePackage(builder,it)
                    }
                    addExcludePackage(builder,packageName)
                }
            } else {
                val includePackage = options.includePackage
                if (includePackage.hasNext()) {
                    while (includePackage.hasNext()) {
                        addIncludePackage(builder,includePackage.next())
                    }
                    //                    addIncludePackage(builder,packageName)
                }else {
                    val excludePackage = options.excludePackage
                    if (excludePackage.hasNext()) {
                        while (excludePackage.hasNext()) {
                            addExcludePackage(builder, excludePackage.next())
                        }
                    }

                    addExcludePackage(builder, packageName)
                }
                
            }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = Settings.systemProxyEnabled
            if (systemProxyEnabled) builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer, options.httpProxyServerPort
                )
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        return service.openTun(generation, pfd) {
            verifyPlatformProtect(generation)
        }
    }

    private fun verifyPlatformProtect(generation: Long) {
        DatagramSocket(null).use { socket ->
            socket.bind(InetSocketAddress(0))
            val protected = protect(socket)
            VpnSessionCoordinator.event(
                "protect_result",
                generation,
                "source=post_tun_probe success=$protected",
                if (protected) Log.INFO else Log.ERROR,
            )
            if (!protected) {
                error("android: post-TUN VpnService.protect self-check failed")
            }
        }
    }

//    override fun writeLog(message: String) = service.writeLog(message)

    override fun sendNotification(notification: Notification) {
//        service.sendNotification(notification)
    }
}
