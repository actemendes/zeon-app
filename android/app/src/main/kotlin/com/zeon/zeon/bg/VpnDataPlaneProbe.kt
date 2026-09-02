package com.zeon.zeon.bg

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException

internal data class VpnDataPlaneTargetResult(
    val id: String,
    val ready: Boolean,
    val failureCategory: String = "none",
)

internal data class VpnDataPlaneProbeResult(
    val ready: Boolean,
    val targets: List<VpnDataPlaneTargetResult>,
)

/**
 * Bounded, fixed-target proof that Android application traffic traverses the
 * established VPN Network. This is intentionally separate from core URL-test:
 * the latter dials an outbound directly and does not exercise Android -> TUN.
 */
internal class VpnDataPlaneProbe(
    private val connectivity: ConnectivityManager,
) {
    companion object {
        // Match the core's established URL-test boundary. This is a cancellation
        // bound only; readiness still requires a real HTTPS response.
        private const val PROBE_TIMEOUT_MILLIS = 5_000
        private val targets = listOf(
            "zeon_204" to "https://zeon-vps.link/generate_204",
            "gstatic_204" to "https://www.gstatic.com/generate_204",
        )

        internal fun hasReadyTarget(results: List<VpnDataPlaneTargetResult>): Boolean =
            results.size == targets.size &&
                results.map { it.id }.toSet().size == targets.size &&
                results.any { it.ready }
    }

    suspend fun probe(): VpnDataPlaneProbeResult {
        val network = findVpnNetwork()
            ?: return VpnDataPlaneProbeResult(
                ready = false,
                targets = targets.map { (id, _) ->
                    VpnDataPlaneTargetResult(id, ready = false, failureCategory = "vpn_network_missing")
                },
            )
        val results = coroutineScope {
            targets.map { (id, endpoint) ->
                async(Dispatchers.IO) { probeTarget(network, id, endpoint) }
            }.awaitAll()
        }
        return VpnDataPlaneProbeResult(
            ready = hasReadyTarget(results),
            targets = results,
        )
    }

    private fun findVpnNetwork(): Network? =
        connectivity.allNetworks.firstOrNull { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }

    private suspend fun probeTarget(
        network: Network,
        id: String,
        endpoint: String,
    ): VpnDataPlaneTargetResult = withContext(Dispatchers.IO) {
        var connection: HttpsURLConnection? = null
        try {
            val url = URL(endpoint)
            // DNS must use the same VPN Network as the HTTPS socket.
            if (network.getAllByName(url.host).isEmpty()) {
                return@withContext VpnDataPlaneTargetResult(id, false, "dns_empty")
            }
            connection = network.openConnection(url) as HttpsURLConnection
            connection.connectTimeout = PROBE_TIMEOUT_MILLIS
            connection.readTimeout = PROBE_TIMEOUT_MILLIS
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("User-Agent", "ZEON-android-readiness/1")
            connection.setRequestProperty("Connection", "close")
            val status = connection.responseCode
            VpnDataPlaneTargetResult(
                id = id,
                ready = status in 200..399,
                failureCategory = if (status in 200..399) "none" else "http_status",
            )
        } catch (_: UnknownHostException) {
            VpnDataPlaneTargetResult(id, false, "dns")
        } catch (_: SocketTimeoutException) {
            VpnDataPlaneTargetResult(id, false, "timeout")
        } catch (_: SSLException) {
            VpnDataPlaneTargetResult(id, false, "tls")
        } catch (_: ConnectException) {
            VpnDataPlaneTargetResult(id, false, "connect")
        } catch (_: IOException) {
            VpnDataPlaneTargetResult(id, false, "io")
        } catch (_: Throwable) {
            VpnDataPlaneTargetResult(id, false, "unexpected")
        } finally {
            connection?.disconnect()
        }
    }
}
