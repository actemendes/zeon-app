package test.com.zeon.zeon.bg

import android.os.ParcelFileDescriptor
import com.zeon.zeon.bg.TunDescriptorOwner
import com.zeon.zeon.bg.VpnSessionCoordinator
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class TunDescriptorOwnerInstrumentedTest {
    fun duplicateOpenIsRejectedAndNewDescriptorIsClosed() {
        val owner = TunDescriptorOwner()
        val generation = VpnSessionCoordinator.next("tun_duplicate")
        val first = descriptor()
        val duplicate = descriptor()
        owner.open(generation, first)

        check(runCatching { owner.open(generation, duplicate) }.isFailure)
        check(!duplicate.fileDescriptor.valid())
        check(owner.hasOpenDescriptor(generation))
        check(owner.close(generation, "test"))
        check(!first.fileDescriptor.valid())
    }

    fun validationFailureClosesEstablishedDescriptor() {
        val owner = TunDescriptorOwner()
        val generation = VpnSessionCoordinator.next("tun_validation_failure")
        val descriptor = descriptor()

        check(
            runCatching {
                owner.open(generation, descriptor) {
                    error("simulated protect failure")
                }
            }.isFailure,
        )
        check(!descriptor.fileDescriptor.valid())
        check(!owner.hasOpenDescriptor(generation))
    }

    fun stopDuringOpenRejectsStaleDescriptor() {
        val owner = TunDescriptorOwner()
        val generation = VpnSessionCoordinator.next("tun_open_race")
        val descriptor = descriptor()
        val validationStarted = CountDownLatch(1)
        val continueValidation = CountDownLatch(1)
        var failure: Throwable? = null
        val worker = thread {
            failure = runCatching {
                owner.open(generation, descriptor) {
                    validationStarted.countDown()
                    check(continueValidation.await(2, TimeUnit.SECONDS))
                }
            }.exceptionOrNull()
        }

        check(validationStarted.await(2, TimeUnit.SECONDS))
        VpnSessionCoordinator.next("tun_stop_during_open")
        continueValidation.countDown()
        worker.join(2_000)

        check(failure != null)
        check(!descriptor.fileDescriptor.valid())
        check(!owner.hasOpenDescriptor(generation))
    }

    fun repeatedStartStopDoesNotGrowDescriptorCount() {
        val owner = TunDescriptorOwner()
        // Execute the complete measured path before taking the baseline.
        // ART, logcat and procfs may open process-wide descriptors lazily
        // while this code becomes hot; a single owner cycle does not exercise
        // that path. A second identical batch must not retain descriptors.
        runOwnershipCycles(owner, "tun_stress_warmup")
        val before = fdCount()
        runOwnershipCycles(owner, "tun_stress")
        val after = fdCount()
        check(after <= before + 2) { "file descriptor count grew from $before to $after" }
    }

    private fun runOwnershipCycles(owner: TunDescriptorOwner, prefix: String) {
        repeat(100) { index ->
            val generation = VpnSessionCoordinator.next("${prefix}_$index")
            val descriptor = descriptor()
            owner.open(generation, descriptor)
            check(owner.close(generation, "stress"))
            check(!descriptor.fileDescriptor.valid())
        }
    }

    fun rapidRestartIsIdempotent() {
        val owner = TunDescriptorOwner()
        repeat(20) { index ->
            val generation = VpnSessionCoordinator.next("tun_restart_$index")
            owner.open(generation, descriptor())
            check(owner.close(generation, "restart"))
            check(!owner.close(generation, "restart_duplicate"))
        }
    }

    private fun descriptor(): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        pipe[1].close()
        return pipe[0]
    }

    private fun fdCount(): Int = File("/proc/self/fd").list()?.size
        ?: error("cannot inspect /proc/self/fd")
}
