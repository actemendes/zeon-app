package com.zeon.zeon.bg

import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import androidx.core.content.ContextCompat
import com.zeon.zeon.Settings
import com.zeon.zeon.utils.GrpcClientProvider
import com.hiddify.core.api.v2.hcore.CoreClient
import com.hiddify.core.api.v2.hcore.SelectOutboundRequest
import kotlinx.coroutines.*

/** Narrow, caller-authenticated API. No profiles, URLs, secrets or arbitrary commands cross IPC. */
class WatchBackupBridgeService : Service() {
    companion object {
        const val DESCRIPTOR = "com.zeon.watch.backup.v1"
        const val ENSURE = IBinder.FIRST_CALL_TRANSACTION
        const val STATUS = ENSURE + 1
        const val RELEASE = ENSURE + 2
        const val EXTRA_BACKUP = "zeon.watch.backup"
        // Public signing certificate of the owner-installed ZEON.AI prototype, not a secret.
        private const val AI_CERT = "34e3154e34a1547549d30fd91f4866014323b0005e26e16b8787cecd28099ebd"
        suspend fun selectAuto() = withContext(Dispatchers.IO) {
            GrpcClientProvider.grpcClient.create(CoreClient::class).SelectOutbound().executeBlocking(
                SelectOutboundRequest(group_tag = "select", outbound_tag = "balance"),
            )
            check(Settings.persistAutoProxySelection()) { "Cannot persist Auto selection" }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    @Volatile private var state = 0 // idle, starting, ready, failed
    private var ownedGeneration = 0L
    private var request: Job? = null
    private var clientToken: IBinder? = null
    private val clientDeath = IBinder.DeathRecipient { scope.launch { releaseClient() } }

    private fun releaseClient() {
        clientToken?.let { runCatching { it.unlinkToDeath(clientDeath, 0) } }
        clientToken = null
        request?.cancel(); request = null
        stopOwned()
        state = 0
    }

    private fun authorize() {
        val uid = Binder.getCallingUid()
        val packages = packageManager.getPackagesForUid(uid).orEmpty()
        val cert = AI_CERT.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        check(Settings.isWatch) { "Watch only" }
        if (packages.size != 1 || packages[0] != "ai.zeon.watch" ||
            !packageManager.hasSigningCertificate("ai.zeon.watch", cert, PackageManager.CERT_INPUT_SHA256)) {
            throw SecurityException("Untrusted backup client")
        }
    }

    private val api = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != ENSURE && code != STATUS && code != RELEASE) return super.onTransact(code, data, reply, flags)
            authorize()
            data.enforceInterface(DESCRIPTOR)
            if (code == ENSURE) {
                val token = requireNotNull(data.readStrongBinder())
                scope.launch {
                    if (clientToken == null) {
                        try { token.linkToDeath(clientDeath, 0); clientToken = token; ensureStarted() }
                        catch (_: android.os.RemoteException) { releaseClient() }
                    } else if (clientToken == token && (state < 0 || (state == 2 && !routeAlive()))) {
                        // Self-heal for the same lease: a failed attempt or a route that stopped since READY.
                        request?.cancel(); request = null; stopOwned(); state = 0
                        ensureStarted()
                    }
                }
            }
            if (code == STATUS && state == 2 && !routeAlive()) {
                reply?.writeNoException(); reply?.writeInt(1)
                return true
            }
            if (code == RELEASE) scope.launch { releaseClient() }
            reply?.writeNoException()
            reply?.writeInt(state)
            return true
        }
    }

    override fun onBind(intent: Intent): IBinder = api

    private fun routeAlive() = VpnSessionSnapshotCoordinator.current().provesConnected()

    private fun ensureStarted() {
        if (request != null || state != 0) return
        state = 1
        request = scope.launch {
            try {
                val snapshot = VpnSessionSnapshotCoordinator.current()
                check(snapshot.phase !in setOf(VpnSessionPhase.STOPPING, VpnSessionPhase.STOP_REQUESTED))
                if (snapshot.phase in setOf(VpnSessionPhase.IDLE, VpnSessionPhase.DISCONNECTED, VpnSessionPhase.FAILED)) {
                    check(Settings.activeConfigPath.isNotBlank() && Settings.baseDir != "./") { "Open ZEON once to configure a profile" }
                    ownedGeneration = VpnSessionCoordinator.next("watch_ai_backup")
                    ContextCompat.startForegroundService(this@WatchBackupBridgeService,
                        Intent(this@WatchBackupBridgeService, WatchProxyService::class.java)
                            .putExtra(BoxService.EXTRA_SESSION_GENERATION, ownedGeneration)
                            .putExtra(EXTRA_BACKUP, true))
                }
                // Owned starts verify the gateway inside BoxService (up to 45 s); the watch waits 60 s.
                withTimeout(55_000) {
                    while (true) {
                        val current = VpnSessionSnapshotCoordinator.current()
                        if (ownedGeneration != 0L) check(VpnSessionCoordinator.isCurrent(ownedGeneration))
                        if (ownedGeneration == 0L || current.generation == ownedGeneration) {
                            check(current.phase !in setOf(VpnSessionPhase.FAILED, VpnSessionPhase.STOPPING, VpnSessionPhase.STOP_REQUESTED))
                            if (current.provesConnected()) break
                        }
                        delay(200)
                    }
                    // An already user-owned proxy remains user-owned. Keep the user's server when it
                    // already reaches the gateway; switch to Auto only when it does not.
                    if (ownedGeneration == 0L) {
                        val generation = VpnSessionSnapshotCoordinator.current().generation
                        val current = { VpnSessionSnapshotCoordinator.current().let { it.generation == generation && it.provesConnected() } }
                        val direct = runCatching { WatchProxySettings.verifyTraffic(backup = true, timeoutMs = 6_000L, isCurrent = current) }.getOrDefault(false)
                        if (!direct) {
                            selectAuto()
                            check(WatchProxySettings.verifyTraffic(backup = true, timeoutMs = 40_000L, isCurrent = current)) { "User session ended" }
                        }
                    }
                }
                state = 2
            } catch (e: TimeoutCancellationException) {
                state = -1
                android.util.Log.w("ZeonBackup", "start timed out")
                stopOwned()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                state = -1
                android.util.Log.w("ZeonBackup", "start failed: ${e.javaClass.simpleName}")
                stopOwned()
            }
        }
    }

    private fun stopOwned() {
        if (ownedGeneration > 0 && VpnSessionCoordinator.isCurrent(ownedGeneration)) BoxService.stop()
        ownedGeneration = 0
    }

    override fun onDestroy() {
        releaseClient()
        scope.cancel()
        super.onDestroy()
    }
}
