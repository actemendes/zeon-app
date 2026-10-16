package com.zeon.zeon.bg

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings.Global
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** A persisted lease prevents overwriting a proxy configured by someone else. */
object WatchProxySettings {
    const val PORT = 12334
    private const val ADDRESS = "127.0.0.1:12334"
    private const val PREFS = "watch_proxy_lease"

    private data class Owner(var stoppedThrough: Long = 0, var destroyed: Boolean = false)
    private val owners = java.util.WeakHashMap<Context, Owner>()
    private var leaseOwner: Context? = null
    private var leaseGeneration: Long = 0

    @Synchronized fun stop(context: Context, generation: Long, destroyed: Boolean = false) {
        val owner = owners.getOrPut(context) { Owner() }
        owner.stoppedThrough = maxOf(owner.stoppedThrough, generation)
        owner.destroyed = owner.destroyed || destroyed
        if (leaseOwner === context && (destroyed || leaseGeneration <= generation)) {
            restore(context)
            leaseOwner = null
        }
    }

    fun permitted(context: Context) = context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    @Synchronized fun enable(context: Context, generation: Long) {
        val owner = owners.getOrPut(context) { Owner() }
        check(!owner.destroyed && generation > owner.stoppedThrough) { "Stopped watch proxy owner" }
        check(VpnSessionCoordinator.isCurrent(generation)) { "Stale watch proxy start" }
        check(permitted(context)) { "Watch proxy requires ADB WRITE_SECURE_SETTINGS grant" }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val resolver = context.contentResolver
        if (prefs.getBoolean("owned", false) && Global.getString(resolver, "http_proxy") == ADDRESS) {
            check(leaseOwner === context && leaseGeneration == generation) { "Another watch proxy lease is active" }
            return
        }
        val previous = Global.getString(resolver, "http_proxy")
        check(previous.isNullOrBlank() || previous == ":0") { "Another system proxy is configured" }
        check(Global.getString(resolver, "global_http_proxy_host").isNullOrBlank()) { "Another proxy host is configured" }
        check(Global.getString(resolver, "global_proxy_pac_url").isNullOrBlank()) { "A PAC proxy is configured" }
        check(prefs.edit().putBoolean("owned", true).putString("previous", previous).commit())
        leaseOwner = context
        leaseGeneration = generation
        check(Global.putString(resolver, "http_proxy", ADDRESS)) { "Cannot set watch proxy" }
    }

    @Synchronized fun restore(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("owned", false)) return
        if (!permitted(context)) return // Keep the lease for recovery after the grant returns.
        val resolver = context.contentResolver
        if (Global.getString(resolver, "http_proxy") == ADDRESS) {
            // :0 asks ConnectivityService to clear its live ProxyInfo too.
            if (!Global.putString(resolver, "http_proxy", prefs.getString("previous", null)?.takeUnless { it.isBlank() } ?: ":0")) return
        }
        prefs.edit().clear().commit()
    }

    /** Explicit proxy, normal TLS verification, bounded and independent of system proxy settings. */
    fun verifyTraffic() {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", PORT))
        val connection = URL("https://www.gstatic.com/generate_204").openConnection(proxy) as HttpsURLConnection
        try {
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.useCaches = false
            check(connection.responseCode == 204) { "Watch proxy HTTPS verification failed" }
        } finally { connection.disconnect() }
    }
}
