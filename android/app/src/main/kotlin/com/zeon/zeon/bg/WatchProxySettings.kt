package com.zeon.zeon.bg

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings.Global
import android.os.SystemClock
import kotlinx.coroutines.delay
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

    /** Auto selection needs time to find its first usable outbound after core start. */
    suspend fun verifyTraffic(backup: Boolean = false, timeoutMs: Long = if (backup) 45_000L else 30_000L, isCurrent: () -> Boolean): Boolean {
        // Backup starts on restricted mobile networks, where Auto may test many outbounds first.
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        var lastError: Exception? = null
        while (SystemClock.elapsedRealtime() < deadline && isCurrent()) {
            val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", PORT))
            val connection = URL(if (backup) "https://watch.zeon-vps.online/health" else "https://www.gstatic.com/generate_204").openConnection(proxy) as HttpsURLConnection
            try {
                connection.connectTimeout = 3000
                connection.readTimeout = 3000
                connection.useCaches = false
                check(connection.responseCode == if (backup) 200 else 204) { "Watch proxy HTTPS verification failed" }
                return isCurrent()
            } catch (error: java.io.IOException) {
                lastError = error
            } catch (error: IllegalStateException) {
                lastError = error
            } finally { connection.disconnect() }
            delay(750L)
        }
        if (!isCurrent()) return false
        throw lastError ?: IllegalStateException("Watch proxy readiness timed out")
    }
}
