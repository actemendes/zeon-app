package test.com.zeon.zeon.bg

import android.os.Looper
import com.zeon.zeon.bg.CoreShutdownDispatcher
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
}
