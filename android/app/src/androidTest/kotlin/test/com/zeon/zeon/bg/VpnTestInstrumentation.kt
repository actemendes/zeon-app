package test.com.zeon.zeon.bg

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import test.com.zeon.zeon.performance.SampledBitmapDecoderInstrumentedTest
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

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val targetPackage = targetContext.packageName
        if (targetPackage == PRODUCTION_PACKAGE || !targetPackage.endsWith(VALIDATION_SUFFIX)) {
            finish(
                Activity.RESULT_CANCELED,
                Bundle().apply {
                    putString(
                        "stream",
                        "Refusing instrumentation target=$targetPackage; " +
                            "tests require an isolated .validation application.",
                    )
                },
            )
            return
        }

        val generationTests = VpnSessionCoordinatorInstrumentedTest()
        val startupTests = CoreStartupGateInstrumentedTest()
        val tunTests = TunDescriptorOwnerInstrumentedTest()
        val activeSessionTests = ActiveSessionInstrumentedTest()
        val permissionTests = VpnPermissionAndConnectedGateInstrumentedTest()
        val startPermissionTests = StartPermissionRequestCoordinatorInstrumentedTest()
        val snapshotTests = VpnSessionSnapshotInstrumentedTest()
        val shutdownTests = CoreShutdownDispatcherInstrumentedTest()
        val bitmapTests = SampledBitmapDecoderInstrumentedTest(targetContext)
        val tests = mutableListOf(
            TestCase(generationTests.javaClass.name, "generationIsStrictlyMonotonic") {
                generationTests.generationIsStrictlyMonotonic()
            },
            TestCase(generationTests.javaClass.name, "staleExternalGenerationCannotReplaceCurrent") {
                generationTests.staleExternalGenerationCannotReplaceCurrent()
            },
            TestCase(
                generationTests.javaClass.name,
                "preemptiveStopGenerationIsStrictlyNewerThanNativeAndDartFloors",
            ) {
                generationTests.preemptiveStopGenerationIsStrictlyNewerThanNativeAndDartFloors()
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
            TestCase(activeSessionTests.javaClass.name, "teardownOrderIsStableAndCloseIsIdempotent") {
                activeSessionTests.teardownOrderIsStableAndCloseIsIdempotent()
            },
            TestCase(snapshotTests.javaClass.name, "connectedRequiresEveryGate") {
                snapshotTests.connectedRequiresEveryGate()
            },
            TestCase(snapshotTests.javaClass.name, "nonConnectedPhaseCannotPassTheGate") {
                snapshotTests.nonConnectedPhaseCannotPassTheGate()
            },
            TestCase(snapshotTests.javaClass.name, "duplicateSelectedOutboundDoesNotPublishANewSnapshot") {
                snapshotTests.duplicateSelectedOutboundDoesNotPublishANewSnapshot()
            },
            TestCase(snapshotTests.javaClass.name, "terminalStopIsTypedCleanAndIdempotent") {
                snapshotTests.terminalStopIsTypedCleanAndIdempotent()
            },
            TestCase(snapshotTests.javaClass.name, "repeatedStopPublishesNewestGenerationAndNextStartIsNewer") {
                snapshotTests.repeatedStopPublishesNewestGenerationAndNextStartIsNewer()
            },
            TestCase(snapshotTests.javaClass.name, "alreadyStoppedExternalStopPromotesTheTerminalGeneration") {
                snapshotTests.alreadyStoppedExternalStopPromotesTheTerminalGeneration()
            },
            TestCase(shutdownTests.javaClass.name, "nativeCoreCloseNeverRunsOnMainLooper") {
                shutdownTests.nativeCoreCloseNeverRunsOnMainLooper()
            },
            TestCase(shutdownTests.javaClass.name, "hungNativeCloseTimesOutWithoutAllowingConcurrentRestart") {
                shutdownTests.hungNativeCloseTimesOutWithoutAllowingConcurrentRestart()
            },
        )
        listOf(
            "firstConnectPermissionGrantedCompletesCurrentAttempt" to permissionTests::firstConnectPermissionGrantedCompletesCurrentAttempt,
            "permissionDeniedDoesNotBecomeGranted" to permissionTests::permissionDeniedDoesNotBecomeGranted,
            "closedDialogIsDenied" to permissionTests::closedDialogIsDenied,
            "delayedPermissionUsesBarrierAndKeepsGeneration" to permissionTests::delayedPermissionUsesBarrierAndKeepsGeneration,
            "stopWhilePermissionPendingMakesResultStale" to permissionTests::stopWhilePermissionPendingMakesResultStale,
            "restartWhilePermissionPendingMakesOldResultStale" to permissionTests::restartWhilePermissionPendingMakesOldResultStale,
            "duplicatePermissionCallbackCompletesOnlyOnce" to permissionTests::duplicatePermissionCallbackCompletesOnlyOnce,
            "stalePermissionResultCannotCompleteNewGeneration" to permissionTests::stalePermissionResultCannotCompleteNewGeneration,
            "commandEndpointWithoutTunCannotPublishStarted" to permissionTests::commandEndpointWithoutTunCannotPublishStarted,
            "tunWithoutMobileStartCannotPublishStarted" to permissionTests::tunWithoutMobileStartCannotPublishStarted,
            "oldGenerationCoreSuccessCannotPublishStarted" to permissionTests::oldGenerationCoreSuccessCannotPublishStarted,
            "reconnectAfterPermissionFailureNeedsNoProcessRestart" to permissionTests::reconnectAfterPermissionFailureNeedsNoProcessRestart,
        ).forEach { (name, body) ->
            tests += TestCase(permissionTests.javaClass.name, name) { body() }
        }
        listOf(
            "bothPermissionsMissingAreSerializedNotificationThenVpn" to
                startPermissionTests::bothPermissionsMissingAreSerializedNotificationThenVpn,
            "notificationGrantedThenVpnGrantedCompletesOneAttempt" to
                startPermissionTests::notificationGrantedThenVpnGrantedCompletesOneAttempt,
            "vpnAlreadyGrantedWaitsOnlyForNotification" to
                startPermissionTests::vpnAlreadyGrantedWaitsOnlyForNotification,
            "notificationDeniedTerminatesAttempt" to
                startPermissionTests::notificationDeniedTerminatesAttempt,
            "vpnDeniedTerminatesAttempt" to startPermissionTests::vpnDeniedTerminatesAttempt,
            "closedDialogIsDenied" to startPermissionTests::closedDialogIsDenied,
            "delayedCallbacksKeepTheOwningGeneration" to
                startPermissionTests::delayedCallbacksKeepTheOwningGeneration,
            "duplicateCallbackCannotCompleteTwice" to
                startPermissionTests::duplicateCallbackCannotCompleteTwice,
            "stopDuringDialogCancelsPendingAttempt" to
                startPermissionTests::stopDuringDialogCancelsPendingAttempt,
            "processRecreationCancelsOldDialogOwnership" to
                startPermissionTests::processRecreationCancelsOldDialogOwnership,
            "staleDialogResultReevaluatesButDoesNotCompleteNewGenerationDirectly" to
                startPermissionTests::staleDialogResultReevaluatesButDoesNotCompleteNewGenerationDirectly,
            "successfulFirstStartNeedsNoSecondBegin" to
                startPermissionTests::successfulFirstStartNeedsNoSecondBegin,
        ).forEach { (name, body) ->
            tests += TestCase(startPermissionTests.javaClass.name, name) { body() }
        }
        listOf(
            "largeLandscapeIsSampled" to bitmapTests::largeLandscapeIsSampled,
            "largePortraitIsSampled" to bitmapTests::largePortraitIsSampled,
            "smallImageIsNotUpscaled" to bitmapTests::smallImageIsNotUpscaled,
            "squareImageIsSampled" to bitmapTests::squareImageIsSampled,
            "veryWideImageIsBounded" to bitmapTests::veryWideImageIsBounded,
            "veryTallImageIsBounded" to bitmapTests::veryTallImageIsBounded,
            "corruptFileIsRejected" to bitmapTests::corruptFileIsRejected,
            "emptyByteArrayIsRejected" to bitmapTests::emptyByteArrayIsRejected,
            "truncatedStreamIsRejected" to bitmapTests::truncatedStreamIsRejected,
            "excessiveDimensionsAreSampledWithoutOverflow" to
                bitmapTests::excessiveDimensionsAreSampledWithoutOverflow,
            "repeatedDecodeKeepsStableDimensions" to bitmapTests::repeatedDecodeKeepsStableDimensions,
            "parallelDecodeIsIndependent" to bitmapTests::parallelDecodeIsIndependent,
            "qrLikeImageRemainsPixelSharpWhenSamplingIsNotNeeded" to
                bitmapTests::qrLikeImageRemainsPixelSharpWhenSamplingIsNotNeeded,
            "notificationOrProfileIconIsNotUpscaled" to
                bitmapTests::notificationOrProfileIconIsNotUpscaled,
        ).forEach { (name, body) ->
            tests += TestCase(bitmapTests.javaClass.name, name) { body() }
        }

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
        const val PRODUCTION_PACKAGE = "com.zeon.hiddify"
        const val VALIDATION_SUFFIX = ".validation"
        const val STATUS_START = 1
        const val STATUS_OK = 0
        const val STATUS_FAILURE = -2
    }
}
