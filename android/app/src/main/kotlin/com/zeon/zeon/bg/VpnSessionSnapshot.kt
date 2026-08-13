package com.zeon.zeon.bg

import android.os.Process
import android.os.SystemClock
import androidx.lifecycle.MutableLiveData
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

enum class VpnSessionPhase {
    IDLE,
    PERMISSION_REQUIRED,
    START_REQUESTED,
    STARTING_PLATFORM,
    STARTING_CORE,
    WAITING_TUN,
    VERIFYING,
    CONNECTED,
    STOP_REQUESTED,
    STOPPING,
    DISCONNECTED,
    FAILED,
}

internal fun phaseAfterCommandEndpointReady(current: VpnSessionPhase): VpnSessionPhase =
    when (current) {
        VpnSessionPhase.VERIFYING,
        VpnSessionPhase.CONNECTED,
        -> current
        else -> VpnSessionPhase.WAITING_TUN
    }

enum class VpnStopSource(
    val wireValue: String,
    val clearsExpectedRunning: Boolean,
) {
    NONE("", false),
    FLUTTER("flutter", true),
    NOTIFICATION("notification", true),
    TILE("tile", true),
    SHORTCUT("shortcut", true),
    REVOKE("revoke", true),
    DESTROY("destroy", false),
    REPLACEMENT("replacement", false),
    INTERNAL("internal", true),
    UNKNOWN("unknown", false);

    companion object {
        fun fromWireValue(value: String?): VpnStopSource =
            entries.firstOrNull { it.wireValue == value?.trim()?.lowercase() } ?: UNKNOWN
    }
}

data class VpnSessionSnapshot(
    val generation: Long,
    val runtimeEpoch: String,
    val sequenceNumber: Long,
    val snapshotVersion: Long,
    val phase: VpnSessionPhase,
    val requestedAction: String = "",
    val stopSource: VpnStopSource = VpnStopSource.NONE,
    val coreReady: Boolean = false,
    val coreStarted: Boolean = false,
    val commandEndpointReady: Boolean = false,
    val tunnelReady: Boolean = false,
    val protectSucceeded: Boolean = false,
    val platformVpnValidated: Boolean = false,
    val selectedOutboundId: String = "",
    val selectedOutboundLabel: String = "",
    val strategy: String = "",
    val failureCode: String = "",
    val failureOwner: String = "",
    val recoverable: Boolean = false,
) {
    fun provesConnected(): Boolean =
        generation > 0L &&
            phase == VpnSessionPhase.CONNECTED &&
            coreReady &&
            coreStarted &&
            commandEndpointReady &&
            tunnelReady &&
            protectSucceeded &&
            platformVpnValidated &&
            selectedOutboundId.isNotBlank()

    fun toEvent(): Map<String, Any> = mapOf(
        "generation" to generation,
        "runtimeEpoch" to runtimeEpoch,
        "sequenceNumber" to sequenceNumber,
        "snapshotVersion" to snapshotVersion,
        "phase" to phase.name.lowercase(),
        "requestedAction" to requestedAction,
        "stopSource" to stopSource.wireValue,
        "coreReady" to coreReady,
        "coreStarted" to coreStarted,
        "commandEndpointReady" to commandEndpointReady,
        "tunnelReady" to tunnelReady,
        "protectSucceeded" to protectSucceeded,
        "platformVpnValidated" to platformVpnValidated,
        "selectedOutboundId" to selectedOutboundId,
        "selectedOutboundLabel" to selectedOutboundLabel,
        "strategy" to strategy,
        "failureCode" to failureCode,
        "failureOwner" to failureOwner,
        "recoverable" to recoverable,
    )
}

/**
 * The Android process-wide authority for state presented to Flutter and the
 * foreground notification. Values are immutable and published atomically.
 */
object VpnSessionSnapshotCoordinator {
    private val runtimeEpoch =
        "${Process.myPid()}-${SystemClock.elapsedRealtimeNanos().toString(16)}"
    private val sequence = AtomicLong(0L)
    private val version = AtomicLong(0L)
    private val lock = Any()

    private val initialSnapshot =
        VpnSessionSnapshot(
            generation = 0L,
            runtimeEpoch = runtimeEpoch,
            sequenceNumber = sequence.incrementAndGet(),
            snapshotVersion = version.incrementAndGet(),
            phase = VpnSessionPhase.IDLE,
        )
    private val authoritative = AtomicReference(initialSnapshot)
    val snapshots = MutableLiveData(initialSnapshot)

    fun current(): VpnSessionSnapshot = authoritative.get()

    fun begin(generation: Long, action: String): VpnSessionSnapshot = update(generation) {
        VpnSessionSnapshot(
            generation = generation,
            runtimeEpoch = runtimeEpoch,
            sequenceNumber = 0L,
            snapshotVersion = 0L,
            phase = VpnSessionPhase.START_REQUESTED,
            requestedAction = action,
        )
    }

    fun transition(
        generation: Long,
        phase: VpnSessionPhase,
        mutate: (VpnSessionSnapshot) -> VpnSessionSnapshot = { it },
    ): VpnSessionSnapshot = update(generation) { previous ->
        mutate(previous).copy(phase = phase)
    }

    fun selectedOutbound(
        generation: Long,
        outbound: String,
        strategy: String,
    ): VpnSessionSnapshot {
        val normalized = outbound.trim()
        val opaque = if (normalized.isBlank()) "" else sha256(normalized).take(16)
        val label = normalized.substringBefore('§').take(96)
        return update(generation) {
            it.copy(
                selectedOutboundId = opaque,
                selectedOutboundLabel = label,
                strategy = strategy.take(48),
            )
        }
    }

    fun failure(
        generation: Long,
        code: String,
        owner: String,
        recoverable: Boolean,
    ): VpnSessionSnapshot = transition(generation, VpnSessionPhase.FAILED) {
        it.copy(
            failureCode = code.take(96),
            failureOwner = owner.take(48),
            recoverable = recoverable,
        )
    }

    fun requestStop(
        generation: Long,
        source: VpnStopSource,
    ): VpnSessionSnapshot = transition(generation, VpnSessionPhase.STOP_REQUESTED) {
        it.copy(
            requestedAction = "stop",
            stopSource = source,
        )
    }

    /**
     * Publishes a clean terminal state. Repeating the same already-stopped
     * request is intentionally idempotent and does not advance sequence/version.
     */
    fun publishDisconnected(
        generation: Long,
        source: VpnStopSource,
    ): VpnSessionSnapshot = update(generation) { previous ->
        previous.copy(
            phase = VpnSessionPhase.DISCONNECTED,
            requestedAction = "stop",
            stopSource = source,
            coreReady = false,
            coreStarted = false,
            commandEndpointReady = false,
            tunnelReady = false,
            protectSucceeded = false,
            platformVpnValidated = false,
            selectedOutboundId = "",
            selectedOutboundLabel = "",
            strategy = "",
            failureCode = "",
            failureOwner = "",
            recoverable = false,
        )
    }

    private fun update(
        generation: Long,
        transform: (VpnSessionSnapshot) -> VpnSessionSnapshot,
    ): VpnSessionSnapshot = synchronized(lock) {
        val current = current()
        if (generation < current.generation) {
            VpnSessionCoordinator.stale(generation, "vpn_session_snapshot")
            return@synchronized current
        }
        val base = if (generation > current.generation) {
            VpnSessionSnapshot(
                generation = generation,
                runtimeEpoch = runtimeEpoch,
                sequenceNumber = 0L,
                snapshotVersion = 0L,
                phase = VpnSessionPhase.IDLE,
            )
        } else {
            current
        }
        val transformed = transform(base).copy(
            generation = generation,
            runtimeEpoch = runtimeEpoch,
        )
        if (generation == current.generation && transformed == current) {
            return@synchronized current
        }
        val next = transformed.copy(
            sequenceNumber = sequence.incrementAndGet(),
            snapshotVersion = version.incrementAndGet(),
        )
        authoritative.set(next)
        snapshots.postValue(next)
        VpnSessionCoordinator.event(
            "vpn_snapshot",
            generation,
            "runtime_epoch=$runtimeEpoch sequence=${next.sequenceNumber} version=${next.snapshotVersion} phase=${next.phase.name}",
        )
        next
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
