package test.com.zeon.zeon.bg

import android.os.Looper
import com.zeon.zeon.bg.CoreShutdownDispatcher
import com.zeon.zeon.bg.SessionCloseDispatcher
import com.zeon.zeon.bg.CoreNativeOperationCoordinator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
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

    suspend fun hungNativeCloseTimesOutWithoutAllowingConcurrentRestart() = coroutineScope {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CoreShutdownDispatcher.close(timeoutMillis = 100L) {
            CoreNativeOperationCoordinator.exclusive {
                entered.countDown()
                release.await()
            }
        }

        check(entered.await(1L, TimeUnit.SECONDS)) { "native close worker did not start" }
        check(!completed) { "hung native close unexpectedly reported completion" }
        check(!CoreShutdownDispatcher.awaitSettled(timeoutMillis = 50L)) {
            "new core start was allowed while old native close was still running"
        }
        val setupEntered = AtomicBoolean(false)
        val setup = async(Dispatchers.IO) {
            CoreNativeOperationCoordinator.exclusive {
                setupEntered.set(true)
            }
        }
        delay(100L)
        check(!setupEntered.get()) {
            "Mobile.setup entered while a timed-out Mobile.close worker still owned native state"
        }

        release.countDown()
        check(CoreShutdownDispatcher.awaitSettled(timeoutMillis = 1_000L)) {
            "native close did not settle after the worker was released"
        }
        setup.await()
        check(setupEntered.get())
    }

    suspend fun hungListenerStepCannotPreventFollowingTunCleanupStep() {
        val listenerEntered = CountDownLatch(1)
        val releaseListener = CountDownLatch(1)
        val listenerResult = SessionCloseDispatcher.runStep(timeoutMillis = 100L) {
            listenerEntered.countDown()
            releaseListener.await()
        }

        check(listenerEntered.await(1L, TimeUnit.SECONDS)) { "listener close step did not start" }
        check(listenerResult == null) { "hung listener step did not time out" }

        val tunCleanupReached = AtomicBoolean(false)
        val tunResult = SessionCloseDispatcher.runStep(timeoutMillis = 1_000L) {
            tunCleanupReached.set(true)
        }
        check(tunResult?.isSuccess == true)
        check(tunCleanupReached.get()) { "TUN cleanup was hidden by a hung listener step" }
        releaseListener.countDown()
    }

    suspend fun nativeStartAndCloseOperationsAreMutuallyExclusive() = coroutineScope {
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondEntered = AtomicBoolean(false)
        val first = async(Dispatchers.IO) {
            CoreNativeOperationCoordinator.exclusive {
                firstEntered.countDown()
                releaseFirst.await()
            }
        }
        check(firstEntered.await(1L, TimeUnit.SECONDS))
        val second = async(Dispatchers.IO) {
            CoreNativeOperationCoordinator.exclusive {
                secondEntered.set(true)
            }
        }
        delay(100L)
        check(!secondEntered.get()) { "Mobile.start/setup overlapped Mobile.close" }
        releaseFirst.countDown()
        first.await()
        second.await()
        check(secondEntered.get())
    }
}
