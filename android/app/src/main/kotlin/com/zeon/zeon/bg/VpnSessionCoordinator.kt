package com.zeon.zeon.bg

import android.os.Process
import android.os.SystemClock
import android.util.Log
import com.hiddify.core.mobile.Mobile
import java.util.concurrent.atomic.AtomicLong

/**
 * Process-wide gate for VPN session callbacks.
 *
 * The value is supplied by Flutter for user-driven operations and allocated
 * locally for boot/tile operations. It is intentionally not persisted in user
 * preferences and does not change profile or subscription formats.
 */
object VpnSessionCoordinator {
    private const val TAG = "A/VpnSession"
    private val sequence = AtomicLong(0)

    fun current(): Long = sequence.get()

    fun next(reason: String): Long {
        val generation = sequence.incrementAndGet()
        publishToNativeProcess(generation)
        event("vpn_session_generation", generation, "reason=$reason")
        return generation
    }

    /**
     * Atomically allocates a generation newer than both the current native
     * owner and [requested]. Used by an explicit preemptive Stop so a tile or
     * service operation racing with Dart cannot share the same generation and
     * reopen the TUN after the Stop terminal state.
     */
    fun nextAfter(requested: Long, reason: String): Long {
        while (true) {
            val current = sequence.get()
            val requestedFloor = if (requested > 0L) requested else 0L
            val candidate = maxOf(current + 1L, requestedFloor)
            if (sequence.compareAndSet(current, candidate)) {
                publishToNativeProcess(candidate)
                event("vpn_session_generation", candidate, "reason=$reason")
                return candidate
            }
        }
    }

    fun accept(requested: Long, reason: String): Long {
        if (requested <= 0) return next(reason)
        while (true) {
            val current = sequence.get()
            if (requested < current) {
                stale(requested, "generation_accept/$reason")
                return current
            }
            if (requested == current || sequence.compareAndSet(current, requested)) {
                publishToNativeProcess(requested)
                event("vpn_session_generation", requested, "reason=$reason")
                return requested
            }
        }
    }

    fun isCurrent(generation: Long): Boolean = generation > 0 && generation == sequence.get()

    fun stale(generation: Long, source: String) {
        event(
            "stale_callback_ignored",
            generation,
            "source=$source current_generation=${sequence.get()}",
            Log.WARN,
        )
    }

    fun event(name: String, generation: Long, details: String = "", priority: Int = Log.INFO) {
        val suffix = if (details.isBlank()) "" else " $details"
        Log.println(
            priority,
            TAG,
            "event=$name monotonic_ms=${SystemClock.elapsedRealtime()} pid=${Process.myPid()} generation=$generation$suffix",
        )
    }

    private fun publishToNativeProcess(generation: Long) {
        runCatching { Mobile.setSessionGeneration(generation) }
            .onFailure {
                event(
                    "terminal_failure",
                    generation,
                    "phase=session_generation_export error=${it.javaClass.simpleName}",
                    Log.ERROR,
                )
            }
    }
}
