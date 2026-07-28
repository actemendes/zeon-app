package test.com.zeon.zeon.bg

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import kotlinx.coroutines.runBlocking

/**
 * Dependency-free instrumentation runner for the VPN lifecycle invariants.
 *
 * It uses the status bundle keys understood by Android instrumentation tooling
 * and deliberately avoids adding JUnit/AndroidX dependencies to the app.
 */
class VpnTestInstrumentation : Instrumentation() {
    private data class TestCase(
        val className: String,
        val methodName: String,
        val body: suspend () -> Unit,
    )

    override fun onStart() {
        val generationTests = VpnSessionCoordinatorInstrumentedTest()
        val startupTests = CoreStartupGateInstrumentedTest()
        val tunTests = TunDescriptorOwnerInstrumentedTest()
        val tests = listOf(
            TestCase(generationTests.javaClass.name, "generationIsStrictlyMonotonic") {
                generationTests.generationIsStrictlyMonotonic()
            },
            TestCase(generationTests.javaClass.name, "staleExternalGenerationCannotReplaceCurrent") {
                generationTests.staleExternalGenerationCannotReplaceCurrent()
            },
            TestCase(startupTests.javaClass.name, "mobileStartSuccessRequiresEndpointReadiness") {
                startupTests.mobileStartSuccessRequiresEndpointReadiness()
            },
            TestCase(startupTests.javaClass.name, "mobileStartExceptionFailsStartup") {
                startupTests.mobileStartExceptionFailsStartup()
            },
            TestCase(startupTests.javaClass.name, "endpointTimeoutDoesNotBecomeReady") {
                startupTests.endpointTimeoutDoesNotBecomeReady()
            },
            TestCase(startupTests.javaClass.name, "stopDuringStartSupersedesPendingResult") {
                startupTests.stopDuringStartSupersedesPendingResult()
            },
            TestCase(startupTests.javaClass.name, "restartDuringStartSupersedesPendingResult") {
                startupTests.restartDuringStartSupersedesPendingResult()
            },
            TestCase(tunTests.javaClass.name, "duplicateOpenIsRejectedAndNewDescriptorIsClosed") {
                tunTests.duplicateOpenIsRejectedAndNewDescriptorIsClosed()
            },
            TestCase(tunTests.javaClass.name, "validationFailureClosesEstablishedDescriptor") {
                tunTests.validationFailureClosesEstablishedDescriptor()
            },
            TestCase(tunTests.javaClass.name, "stopDuringOpenRejectsStaleDescriptor") {
                tunTests.stopDuringOpenRejectsStaleDescriptor()
            },
            TestCase(tunTests.javaClass.name, "repeatedStartStopDoesNotGrowDescriptorCount") {
                tunTests.repeatedStartStopDoesNotGrowDescriptorCount()
            },
            TestCase(tunTests.javaClass.name, "rapidRestartIsIdempotent") {
                tunTests.rapidRestartIsIdempotent()
            },
        )

        var failures = 0
        tests.forEachIndexed { index, test ->
            sendStatus(STATUS_START, statusBundle(test, index + 1, tests.size))
            try {
                runBlocking { test.body() }
                sendStatus(STATUS_OK, statusBundle(test, index + 1, tests.size))
            } catch (error: Throwable) {
                failures += 1
                sendStatus(
                    STATUS_FAILURE,
                    statusBundle(test, index + 1, tests.size).apply {
                        putString("stack", error.stackTraceToString())
                    },
                )
            }
        }

        finish(
            if (failures == 0) Activity.RESULT_OK else Activity.RESULT_CANCELED,
            Bundle().apply {
                putString("stream", "Ran ${tests.size} VPN instrumentation tests; failures=$failures")
            },
        )
    }

    private fun statusBundle(test: TestCase, current: Int, total: Int) = Bundle().apply {
        putString("id", "VpnTestInstrumentation")
        putString("class", test.className)
        putString("test", test.methodName)
        putInt("current", current)
        putInt("numtests", total)
    }

    private companion object {
        const val STATUS_START = 1
        const val STATUS_OK = 0
        const val STATUS_FAILURE = -2
    }
}
