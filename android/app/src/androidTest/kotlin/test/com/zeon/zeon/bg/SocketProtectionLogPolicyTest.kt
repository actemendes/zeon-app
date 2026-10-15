package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.SocketProtectionLogPolicy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class SocketProtectionLogPolicyTest {
    fun firstSuccessAtZeroIsLoggedAndBurstIsAggregatedAtThirtySeconds() {
        val policy = SocketProtectionLogPolicy()
        check(policy.record(1L, 1L, true, 0L) == SocketProtectionLogPolicy.Emission(true, 1L, 0L, true))
        check(policy.record(1L, 1L, true, 1L) == null)
        check(policy.record(1L, 1L, true, 29_999L) == null)
        check(policy.record(1L, 1L, true, 30_000L) == SocketProtectionLogPolicy.Emission(true, 3L, 30_000L, false))
        check(policy.record(1L, 1L, true, 30_001L) == null)
    }

    fun everyFailureIsLoggedWithoutChangingSuccessWindow() {
        val policy = SocketProtectionLogPolicy()
        policy.record(2L, 2L, true, 0L)
        check(policy.record(2L, 2L, true, 1L) == null)
        repeat(10) {
            check(policy.record(2L, 2L, false, 2L) == SocketProtectionLogPolicy.Emission(false, 1L, 0L, false))
        }
        check(policy.record(1L, 2L, false, 3L)?.success == false)
        check(policy.record(2L, 2L, true, 30_000L)?.count == 2L)
    }

    fun newGenerationGetsImmediateFirstRecordAndOldCallbackCannotResetIt() {
        val policy = SocketProtectionLogPolicy()
        policy.record(10L, 10L, true, 0L)
        check(policy.record(11L, 11L, true, 1L)?.initial == true)
        check(policy.record(10L, 11L, true, 2L) == null)
        check(policy.record(10L, 10L, true, 3L) == null)
        check(policy.record(11L, 11L, true, 30_000L) == null)
        check(policy.record(11L, 11L, true, 30_001L)?.count == 2L)
    }

    fun staleOrInvalidFirstCallbackDoesNotInitializeSampler() {
        val policy = SocketProtectionLogPolicy()
        check(policy.record(0L, 0L, true, 0L) == null)
        check(policy.record(-1L, -1L, true, 0L) == null)
        check(policy.record(100L, 101L, true, 0L) == null)
        check(policy.record(101L, 101L, true, 1L)?.initial == true)
    }

    fun idleWindowWaitsForLiveSocketInsteadOfSchedulingWork() {
        val policy = SocketProtectionLogPolicy()
        policy.record(1L, 1L, true, 0L)
        check(policy.record(1L, 1L, true, 120_000L) == SocketProtectionLogPolicy.Emission(true, 1L, 120_000L, false))
    }

    fun backwardClockFlushesPendingCountAndRebases() {
        val policy = SocketProtectionLogPolicy()
        policy.record(1L, 1L, true, 50_000L)
        policy.record(1L, 1L, true, 50_001L)
        check(policy.record(1L, 1L, true, 0L) == SocketProtectionLogPolicy.Emission(true, 2L, 0L, false))
        check(policy.record(1L, 1L, true, 29_999L) == null)
        check(policy.record(1L, 1L, true, 30_000L)?.count == 2L)
    }

    fun largeClockValuesPreserveIntervalBoundary() {
        val policy = SocketProtectionLogPolicy()
        policy.record(1L, 1L, true, Long.MAX_VALUE - 30_000L)
        check(policy.record(1L, 1L, true, Long.MAX_VALUE - 1L) == null)
        check(policy.record(1L, 1L, true, Long.MAX_VALUE)?.count == 2L)
    }

    fun concurrentSocketSuccessesAreCountedExactlyOnce() {
        val policy = SocketProtectionLogPolicy()
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(8)
        try {
            policy.record(1L, 1L, true, 0L)
            val results = (1..1_000).map {
                pool.submit<SocketProtectionLogPolicy.Emission?> {
                    check(start.await(3L, TimeUnit.SECONDS))
                    policy.record(1L, 1L, true, 1_000L)
                }
            }
            start.countDown()
            check(results.all { it.get(3L, TimeUnit.SECONDS) == null })
            check(policy.record(1L, 1L, true, 30_000L)?.count == 1_001L)
        } finally {
            start.countDown()
            pool.shutdownNow()
        }
    }
}
