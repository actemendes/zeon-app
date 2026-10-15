package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.NotificationUpdateLimiter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger

class NotificationUpdateLimiterTest {
    private fun content(
        speed: String = "1KB/s",
        profile: String = "Profile",
        outbound: String = "server-a",
        phase: String = "CONNECTED",
    ) = NotificationUpdateLimiter.Content(profile, outbound, phase, speed)

    fun firstSampleAtClockZeroPublishesAndTrafficWaitsFiveSeconds() {
        val limiter = NotificationUpdateLimiter()
        val sent = mutableListOf<String>()
        check(limiter.start(1L))
        fun send(at: Long, speed: String) = limiter.publish(1L, content(speed), at, { true }) { sent += speed }
        check(send(0L, "1KB/s"))
        check(!send(1L, "2KB/s"))
        check(!send(4_999L, "3KB/s"))
        check(send(5_000L, "4KB/s"))
        check(sent == listOf("1KB/s", "4KB/s"))
    }

    fun repeatedZeroSpeedIsDeduplicatedButTransitionToZeroIsEventuallyShown() {
        val limiter = NotificationUpdateLimiter()
        val sent = mutableListOf<String>()
        limiter.start(1L)
        fun send(at: Long, speed: String) = limiter.publish(1L, content(speed), at, { true }) { sent += speed }
        check(send(0L, "1KB/s"))
        check(!send(1_000L, "0B/s"))
        check(send(5_000L, "0B/s"))
        check(!send(10_000L, "0B/s"))
        check(!send(60_000L, "0B/s"))
        check(send(60_001L, "2KB/s"))
        check(sent == listOf("1KB/s", "0B/s", "2KB/s"))
    }

    fun profileServerAndRecoveryChangesBypassTrafficInterval() {
        val limiter = NotificationUpdateLimiter()
        val sent = mutableListOf<NotificationUpdateLimiter.Content>()
        limiter.start(1L)
        val samples = listOf(
            content(), content(profile = "Other"), content(profile = "Other", outbound = "server-b"),
            content(profile = "Other", outbound = "server-b", phase = "VERIFYING"),
            content(profile = "Other", outbound = "server-b", phase = "CONNECTED"),
        )
        samples.forEachIndexed { index, sample ->
            check(limiter.publish(1L, sample, index.toLong(), { true }) { sent += sample })
        }
        check(sent == samples)
    }

    fun identicalTextFromDifferentServerStillPublishesImmediately() {
        val limiter = NotificationUpdateLimiter()
        var count = 0
        limiter.start(1L)
        check(limiter.publish(1L, content(outbound = "first-id"), 0L, { true }) { count++ })
        check(limiter.publish(1L, content(outbound = "second-id"), 1L, { true }) { count++ })
        check(count == 2)
    }

    fun newGenerationCanPublishSameContentAndStaleResetIsRejected() {
        val limiter = NotificationUpdateLimiter()
        var count = 0
        check(limiter.start(10L))
        check(limiter.publish(10L, content(), 0L, { true }) { count++ })
        check(limiter.start(11L))
        check(limiter.publish(11L, content(), 1L, { true }) { count++ })
        check(!limiter.start(10L))
        check(!limiter.publish(10L, content("old"), 10_000L, { true }) { count++ })
        check(!limiter.publish(11L, content("new"), 2L, { true }) { count++ })
        check(count == 2)
    }

    fun closeRejectsLateResponseAndSameGenerationRestart() {
        val limiter = NotificationUpdateLimiter()
        var count = 0
        limiter.start(10L)
        limiter.publish(10L, content(), 0L, { true }) { count++ }
        limiter.close()
        check(!limiter.publish(10L, content("late"), 100_000L, { true }) { count++ })
        check(!limiter.start(10L))
        check(limiter.start(11L))
        check(limiter.publish(11L, content(), 100_001L, { true }) { count++ })
        check(count == 2)
    }

    fun lostForegroundOwnershipDoesNotConsumePublication() {
        val limiter = NotificationUpdateLimiter()
        var count = 0
        limiter.start(1L)
        check(!limiter.publish(1L, content(), 0L, { false }) { count++ })
        check(limiter.publish(1L, content(), 1L, { true }) { count++ })
        check(count == 1)
    }

    fun backwardClockRebasesWithoutFreezingUpdates() {
        val limiter = NotificationUpdateLimiter()
        limiter.start(1L)
        check(limiter.publish(1L, content("before"), 10_000L, { true }) {})
        check(limiter.publish(1L, content("reset"), 0L, { true }) {})
        check(!limiter.publish(1L, content("next"), 4_999L, { true }) {})
        check(limiter.publish(1L, content("next"), 5_000L, { true }) {})
    }

    fun largeMonotonicClockDoesNotOverflowElapsedComparison() {
        val limiter = NotificationUpdateLimiter()
        limiter.start(1L)
        check(limiter.publish(1L, content(), Long.MAX_VALUE - 5_000L, { true }) {})
        check(!limiter.publish(1L, content("next"), Long.MAX_VALUE - 1L, { true }) {})
        check(limiter.publish(1L, content("next"), Long.MAX_VALUE, { true }) {})
    }

    fun failedSendDoesNotSuppressTheNextLiveSample() {
        val limiter = NotificationUpdateLimiter()
        limiter.start(1L)
        val failure = IllegalStateException("test publisher failure")
        val caught = runCatching { limiter.publish(1L, content(), 0L, { true }) { throw failure } }.exceptionOrNull()
        check(caught === failure)
        check(limiter.publish(1L, content(), 1L, { true }) {})
    }

    fun concurrentIdenticalSamplesPublishOnlyOnce() {
        val limiter = NotificationUpdateLimiter()
        val sent = AtomicInteger()
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(8)
        try {
            limiter.start(1L)
            val results = (1..64).map {
                pool.submit<Boolean> {
                    check(start.await(3L, TimeUnit.SECONDS))
                    limiter.publish(1L, content(), 0L, { true }) { sent.incrementAndGet() }
                }
            }
            start.countDown()
            check(results.count { it.get(3L, TimeUnit.SECONDS) } == 1)
            check(sent.get() == 1)
        } finally {
            start.countDown()
            pool.shutdownNow()
        }
    }

    fun stopWaitsForCurrentPublicationAndRejectsAllLaterResponses() {
        val limiter = NotificationUpdateLimiter()
        val publishing = CountDownLatch(1)
        val finishPublish = CountDownLatch(1)
        val closing = CountDownLatch(1)
        val sent = AtomicInteger()
        val pool = Executors.newFixedThreadPool(2)
        try {
            limiter.start(1L)
            val publish = pool.submit<Boolean> {
                limiter.publish(1L, content(), 0L, { true }) {
                    publishing.countDown()
                    check(finishPublish.await(3L, TimeUnit.SECONDS))
                    sent.incrementAndGet()
                }
            }
            check(publishing.await(3L, TimeUnit.SECONDS))
            val close = pool.submit {
                closing.countDown()
                limiter.close()
            }
            check(closing.await(3L, TimeUnit.SECONDS))
            check(runCatching { close.get(100L, TimeUnit.MILLISECONDS) }.exceptionOrNull() is TimeoutException)
            finishPublish.countDown()
            check(publish.get(3L, TimeUnit.SECONDS))
            close.get(3L, TimeUnit.SECONDS)
            check(!limiter.publish(1L, content("late"), 30_000L, { true }) { sent.incrementAndGet() })
            check(sent.get() == 1)
        } finally {
            finishPublish.countDown()
            pool.shutdownNow()
        }
    }
}
