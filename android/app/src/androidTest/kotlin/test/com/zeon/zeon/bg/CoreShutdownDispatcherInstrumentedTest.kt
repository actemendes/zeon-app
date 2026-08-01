package test.com.zeon.zeon.bg

import android.os.Looper
import com.zeon.zeon.bg.CoreShutdownDispatcher
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class CoreShutdownDispatcherInstrumentedTest {
    suspend fun nativeCoreCloseNeverRunsOnMainLooper() {
        val invoked = AtomicBoolean(false)
        CoreShutdownDispatcher.close {
            check(Looper.myLooper() !== Looper.getMainLooper()) {
                "native core close ran on the Android main looper"
            }
            invoked.set(true)
        }
        check(invoked.get()) { "native core close callback was not invoked" }
    }

    suspend fun hungNativeCloseTimesOutWithoutAllowingConcurrentRestart() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CoreShutdownDispatcher.close(timeoutMillis = 100L) {
            entered.countDown()
            release.await()
        }

        check(entered.await(1L, TimeUnit.SECONDS)) { "native close worker did not start" }
        check(!completed) { "hung native close unexpectedly reported completion" }
        check(!CoreShutdownDispatcher.awaitSettled(timeoutMillis = 50L)) {
            "new core start was allowed while old native close was still running"
        }

        release.countDown()
        check(CoreShutdownDispatcher.awaitSettled(timeoutMillis = 1_000L)) {
            "native close did not settle after the worker was released"
        }
    }
}
