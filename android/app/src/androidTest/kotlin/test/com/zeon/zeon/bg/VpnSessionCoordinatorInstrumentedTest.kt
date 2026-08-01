package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.VpnSessionCoordinator
import com.zeon.zeon.bg.VpnLifecycleIntentCoordinator
import com.zeon.zeon.bg.CoreProcessOwnerCoordinator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class VpnSessionCoordinatorInstrumentedTest {
    fun generationIsStrictlyMonotonic() {
        val first = VpnSessionCoordinator.next("instrumented_first")
        val second = VpnSessionCoordinator.next("instrumented_second")

        check(second > first)
        check(VpnSessionCoordinator.isCurrent(second))
        check(!VpnSessionCoordinator.isCurrent(first))
    }

    fun staleExternalGenerationCannotReplaceCurrent() {
        val current = VpnSessionCoordinator.next("instrumented_current")
        val accepted = VpnSessionCoordinator.accept(current - 1, "instrumented_stale")

        check(current == accepted)
        check(current == VpnSessionCoordinator.current())
    }

    fun preemptiveStopGenerationIsStrictlyNewerThanNativeAndDartFloors() {
        val nativeCurrent = VpnSessionCoordinator.next("instrumented_native_ahead")
        val rebasedFromStaleDart = VpnSessionCoordinator.nextAfter(
            nativeCurrent - 1,
            "instrumented_preemptive_stop_stale_dart",
        )
        check(rebasedFromStaleDart > nativeCurrent)

        val requestedFutureFloor = rebasedFromStaleDart + 50
        val rebasedFromFutureDart = VpnSessionCoordinator.nextAfter(
            requestedFutureFloor,
            "instrumented_preemptive_stop_future_dart",
        )
        check(rebasedFromFutureDart >= requestedFutureFloor)
        check(VpnSessionCoordinator.isCurrent(rebasedFromFutureDart))
    }

    fun terminalStopBlocksInternalReloadUntilAnExplicitNewConnect() {
        val ownerToken = Any()
        val sessionGeneration = VpnSessionCoordinator.next("instrumented_reload_session")
        val stopGeneration = requireNotNull(
            VpnLifecycleIntentCoordinator.reserveStop(
                requestedGeneration = sessionGeneration,
                preemptive = true,
                reason = "instrumented_reload_stop",
            ),
        )
        check(stopGeneration > sessionGeneration)
        check(
            VpnLifecycleIntentCoordinator.reserveReload(
                ownerToken = ownerToken,
                sessionGeneration = sessionGeneration,
                reloadAllowed = true,
                reason = "instrumented_reload_after_stop",
            ) == null,
        ) { "internal reload superseded a terminal Stop" }

        val explicitConnectGeneration = VpnSessionCoordinator.next("instrumented_explicit_connect")
        check(VpnLifecycleIntentCoordinator.acceptsStart(explicitConnectGeneration))
        val reloadGeneration = VpnLifecycleIntentCoordinator.reserveReload(
            ownerToken = ownerToken,
            sessionGeneration = explicitConnectGeneration,
            reloadAllowed = true,
            reason = "instrumented_reload_after_explicit_connect",
        )
        check(reloadGeneration != null && reloadGeneration > explicitConnectGeneration)

        val stopDuringReload = requireNotNull(
            VpnLifecycleIntentCoordinator.reserveStop(
                requestedGeneration = reloadGeneration,
                preemptive = true,
                reason = "instrumented_stop_between_reload_reserve_and_commit",
            ),
        )
        check(stopDuringReload > reloadGeneration)
        var staleOwnerInstalled = false
        check(
            !VpnLifecycleIntentCoordinator.commitReload(ownerToken, reloadGeneration) {
                staleOwnerInstalled = true
                true
            },
        ) { "reload committed after a newer terminal Stop" }
        check(!staleOwnerInstalled)

        val reconnectBase = VpnSessionCoordinator.next("instrumented_reload_before_connect")
        val committedReloadGeneration = requireNotNull(
            VpnLifecycleIntentCoordinator.reserveReload(
                ownerToken = ownerToken,
                sessionGeneration = reconnectBase,
                reloadAllowed = true,
                reason = "instrumented_reload_commit_before_connect",
            ),
        )
        check(VpnLifecycleIntentCoordinator.commitReload(ownerToken, committedReloadGeneration) { true })
        val newerConnectGeneration = VpnSessionCoordinator.next("instrumented_connect_after_reload_commit")
        var connectOwnerInstalled = false
        check(
            VpnLifecycleIntentCoordinator.commitStart(newerConnectGeneration) {
                connectOwnerInstalled = true
                true
            },
        ) { "explicit Connect could not supersede a committed stale reload generation" }
        check(connectOwnerInstalled)
    }

    fun processCoreOwnerIsExclusiveAcrossServiceInstances() {
        val firstService = Any()
        val secondService = Any()
        val firstGeneration = VpnSessionCoordinator.next("instrumented_core_owner_first")
        check(CoreProcessOwnerCoordinator.tryAcquire(firstService, firstGeneration))

        val secondGeneration = VpnSessionCoordinator.next("instrumented_core_owner_second")
        check(!CoreProcessOwnerCoordinator.tryAcquire(secondService, secondGeneration))
        check(!CoreProcessOwnerCoordinator.release(secondService, secondGeneration))
        check(CoreProcessOwnerCoordinator.release(firstService, firstGeneration))
        check(CoreProcessOwnerCoordinator.tryAcquire(secondService, secondGeneration))
        check(CoreProcessOwnerCoordinator.release(secondService, secondGeneration))
        check(CoreProcessOwnerCoordinator.generationForTesting() == 0L)
    }

    fun destroyCancelsReservedReloadBeforeItCanCommit() {
        val ownerToken = Any()
        val sessionGeneration = VpnSessionCoordinator.next("instrumented_destroy_reload_base")
        val reloadGeneration = requireNotNull(
            VpnLifecycleIntentCoordinator.reserveReload(
                ownerToken = ownerToken,
                sessionGeneration = sessionGeneration,
                reloadAllowed = true,
                reason = "instrumented_destroy_reload_reserved",
            ),
        )
        check(VpnLifecycleIntentCoordinator.cancelPendingReload(ownerToken) == reloadGeneration)
        check(!VpnLifecycleIntentCoordinator.commitReload(ownerToken, reloadGeneration) { true })
        val destroyStop = requireNotNull(
            VpnLifecycleIntentCoordinator.reserveStop(
                requestedGeneration = 0L,
                preemptive = false,
                reason = "instrumented_destroy_after_reload_cancel",
            ),
        )
        check(destroyStop > reloadGeneration)
    }

    fun oldOwnerDestroyCannotSupersedeNewExplicitConnect() {
        val oldOwnerGeneration = VpnSessionCoordinator.next("instrumented_destroy_old_owner")
        val replacementGeneration = VpnSessionCoordinator.next("instrumented_destroy_replacement_connect")
        check(
            VpnLifecycleIntentCoordinator.reserveDestroyStopIfCurrent(
                expectedGeneration = oldOwnerGeneration,
                reason = "instrumented_destroy_after_replacement",
            ) == null,
        ) { "destroyed old owner allocated a Stop over the replacement Connect" }
        check(VpnSessionCoordinator.current() == replacementGeneration)
    }

    suspend fun destroyAndReloadCommitCannotLeaveALateSessionOwner() = coroutineScope {
        repeat(50) { iteration ->
            val ownerToken = Any()
            val baseGeneration = VpnSessionCoordinator.next("instrumented_destroy_commit_base_$iteration")
            val reloadGeneration = requireNotNull(
                VpnLifecycleIntentCoordinator.reserveReload(
                    ownerToken = ownerToken,
                    sessionGeneration = baseGeneration,
                    reloadAllowed = true,
                    reason = "instrumented_destroy_commit_reload_$iteration",
                ),
            )
            val ownerDestroyed = AtomicBoolean(false)
            val activeOwner = AtomicReference<String?>("old")
            val ready = CountDownLatch(2)
            val start = CountDownLatch(1)
            val commit = async(Dispatchers.Default) {
                ready.countDown()
                start.await()
                VpnLifecycleIntentCoordinator.commitReload(ownerToken, reloadGeneration) {
                    if (ownerDestroyed.get()) {
                        false
                    } else {
                        activeOwner.set("new")
                        true
                    }
                }
            }
            val destroy = async(Dispatchers.Default) {
                ready.countDown()
                start.await()
                VpnLifecycleIntentCoordinator.destroyOwner(ownerToken) {
                    ownerDestroyed.set(true)
                    activeOwner.getAndSet(null)
                }
            }
            check(ready.await(1L, java.util.concurrent.TimeUnit.SECONDS))
            start.countDown()
            val committed = commit.await()
            val destruction = destroy.await()

            check(activeOwner.get() == null) {
                "reload owner survived destruction at iteration $iteration"
            }
            if (committed) {
                check(destruction.detachedResource == "new")
            }
        }
    }
}
