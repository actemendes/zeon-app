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
        val tunCallbackTests = TunCallbackOwnershipInstrumentedTest()
        val activeSessionTests = ActiveSessionInstrumentedTest()
        val permissionTests = VpnPermissionAndConnectedGateInstrumentedTest()
        val startPermissionTests = StartPermissionRequestCoordinatorInstrumentedTest()
        val snapshotTests = VpnSessionSnapshotInstrumentedTest()
        val shutdownTests = CoreShutdownDispatcherInstrumentedTest()
        val notificationTests = ServiceNotificationInstrumentedTest()
        val routePolicyTests = VpnRoutePolicyInstrumentedTest()
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
            TestCase(
                generationTests.javaClass.name,
                "terminalStopBlocksInternalReloadUntilAnExplicitNewConnect",
            ) {
                generationTests.terminalStopBlocksInternalReloadUntilAnExplicitNewConnect()
            },
            TestCase(
                generationTests.javaClass.name,
                "processCoreOwnerIsExclusiveAcrossServiceInstances",
            ) {
                generationTests.processCoreOwnerIsExclusiveAcrossServiceInstances()
            },
            TestCase(
                generationTests.javaClass.name,
                "destroyCancelsReservedReloadBeforeItCanCommit",
            ) {
                generationTests.destroyCancelsReservedReloadBeforeItCanCommit()
            },
            TestCase(
                generationTests.javaClass.name,
                "oldOwnerDestroyCannotSupersedeNewExplicitConnect",
            ) {
                generationTests.oldOwnerDestroyCannotSupersedeNewExplicitConnect()
            },
            TestCase(
                generationTests.javaClass.name,
                "replacementCleanupDoesNotFenceItsStartGeneration",
            ) {
                generationTests.replacementCleanupDoesNotFenceItsStartGeneration()
            },
            TestCase(
                generationTests.javaClass.name,
                "replacementTerminalPublicationPrecedesStartCommit",
            ) {
                generationTests.replacementTerminalPublicationPrecedesStartCommit()
            },
            TestCase(
                generationTests.javaClass.name,
                "completedReplacementCannotPublishALateFallbackFailure",
            ) {
                generationTests.completedReplacementCannotPublishALateFallbackFailure()
            },
            TestCase(
                generationTests.javaClass.name,
                "explicitStopSourceDominatesReplacementCleanup",
            ) {
                generationTests.explicitStopSourceDominatesReplacementCleanup()
            },
            TestCase(
                generationTests.javaClass.name,
                "destroyAndReloadCommitCannotLeaveALateSessionOwner",
            ) {
                generationTests.destroyAndReloadCommitCannotLeaveALateSessionOwner()
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
            TestCase(startupTests.javaClass.name, "onlyTheCurrentAcceptingSessionReportsAStartFailure") {
                startupTests.onlyTheCurrentAcceptingSessionReportsAStartFailure()
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
            TestCase(tunTests.javaClass.name, "twoServiceOwnersCannotOpenConcurrentProcessTuns") {
                tunTests.twoServiceOwnersCannotOpenConcurrentProcessTuns()
            },
            TestCase(routePolicyTests.javaClass.name, "ipv4OnlyTunDoesNotInstallIpv6Routes") {
                routePolicyTests.ipv4OnlyTunDoesNotInstallIpv6Routes()
            },
            TestCase(routePolicyTests.javaClass.name, "dualStackTunInstallsIpv6Routes") {
                routePolicyTests.dualStackTunInstallsIpv6Routes()
            },
            TestCase(tunCallbackTests.javaClass.name, "matchingAcceptingGenerationCanOpenTun") {
                tunCallbackTests.matchingAcceptingGenerationCanOpenTun()
            },
            TestCase(tunCallbackTests.javaClass.name, "oldGenerationMismatchIsStaleAndClosesDescriptor") {
                tunCallbackTests.oldGenerationMismatchIsStaleAndClosesDescriptor()
            },
            TestCase(tunCallbackTests.javaClass.name, "currentGenerationNotAcceptingRemainsIncident") {
                tunCallbackTests.currentGenerationNotAcceptingRemainsIncident()
            },
            TestCase(tunCallbackTests.javaClass.name, "missingCurrentSessionWhileWaitingForTunRemainsIncident") {
                tunCallbackTests.missingCurrentSessionWhileWaitingForTunRemainsIncident()
            },
            TestCase(tunCallbackTests.javaClass.name, "staleCallbackCannotReplaceNewGenerationDescriptor") {
                tunCallbackTests.staleCallbackCannotReplaceNewGenerationDescriptor()
            },
            TestCase(tunCallbackTests.javaClass.name, "oldCallbackIsStaleEvenBeforeOldSessionDetaches") {
                tunCallbackTests.oldCallbackIsStaleEvenBeforeOldSessionDetaches()
            },
            TestCase(tunCallbackTests.javaClass.name, "rapidReplacementDoesNotChangeCallbackOwnerGeneration") {
                tunCallbackTests.rapidReplacementDoesNotChangeCallbackOwnerGeneration()
            },
            TestCase(activeSessionTests.javaClass.name, "teardownOrderIsStableAndCloseIsIdempotent") {
                activeSessionTests.teardownOrderIsStableAndCloseIsIdempotent()
            },
            TestCase(activeSessionTests.javaClass.name, "dataPlaneRevalidationIsRevisionedAndSingleFlight") {
                activeSessionTests.dataPlaneRevalidationIsRevisionedAndSingleFlight()
            },
            TestCase(activeSessionTests.javaClass.name, "selectedOutboundRevalidationStartsWithoutPublishedInvalidation") {
                activeSessionTests.selectedOutboundRevalidationStartsWithoutPublishedInvalidation()
            },
            TestCase(snapshotTests.javaClass.name, "connectedRequiresLocalStartupEvidence") {
                snapshotTests.connectedRequiresLocalStartupEvidence()
            },
            TestCase(snapshotTests.javaClass.name, "nonConnectedPhaseCannotPassTheGate") {
                snapshotTests.nonConnectedPhaseCannotPassTheGate()
            },
            TestCase(snapshotTests.javaClass.name, "selectedOutboundChangeInvalidatesConnectedProof") {
                snapshotTests.selectedOutboundChangeInvalidatesConnectedProof()
            },
            TestCase(snapshotTests.javaClass.name, "healthySelectedOutboundChangeKeepsConnectedProof") {
                snapshotTests.healthySelectedOutboundChangeKeepsConnectedProof()
            },
            TestCase(snapshotTests.javaClass.name, "failedSelectedOutboundProbeInvalidatesConnectedProof") {
                snapshotTests.failedSelectedOutboundProbeInvalidatesConnectedProof()
            },
            TestCase(snapshotTests.javaClass.name, "supersededSelectedOutboundProbeRetriesNewestLeaf") {
                snapshotTests.supersededSelectedOutboundProbeRetriesNewestLeaf()
            },
            TestCase(snapshotTests.javaClass.name, "returnedToSameLeafStillRetriesNewestSelectorRevision") {
                snapshotTests.returnedToSameLeafStillRetriesNewestSelectorRevision()
            },
            TestCase(snapshotTests.javaClass.name, "commandEndpointReadinessCannotRegressAnOpenedTun") {
                snapshotTests.commandEndpointReadinessCannotRegressAnOpenedTun()
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
            TestCase(snapshotTests.javaClass.name, "lateFirstStopCannotOverrideReconnectAndSecondStop") {
                snapshotTests.lateFirstStopCannotOverrideReconnectAndSecondStop()
            },
            TestCase(snapshotTests.javaClass.name, "alreadyStoppedExternalStopPromotesTheTerminalGeneration") {
                snapshotTests.alreadyStoppedExternalStopPromotesTheTerminalGeneration()
            },
            TestCase(
                snapshotTests.javaClass.name,
                "replacementCleanupPreservesExpectedRunningAndPublishesDisconnected",
            ) {
                snapshotTests.replacementCleanupPreservesExpectedRunningAndPublishesDisconnected()
            },
            TestCase(
                snapshotTests.javaClass.name,
                "repeatedStopAfterFailurePublishesDisconnectedWithoutAReceiver",
            ) {
                snapshotTests.repeatedStopAfterFailurePublishesDisconnectedWithoutAReceiver()
            },
            TestCase(shutdownTests.javaClass.name, "nativeCoreCloseNeverRunsOnMainLooper") {
                shutdownTests.nativeCoreCloseNeverRunsOnMainLooper()
            },
            TestCase(shutdownTests.javaClass.name, "hungNativeCloseTimesOutWithoutAllowingConcurrentRestart") {
                shutdownTests.hungNativeCloseTimesOutWithoutAllowingConcurrentRestart()
            },
            TestCase(shutdownTests.javaClass.name, "nativeStartAndCloseOperationsAreMutuallyExclusive") {
                shutdownTests.nativeStartAndCloseOperationsAreMutuallyExclusive()
            },
            TestCase(
                shutdownTests.javaClass.name,
                "hungListenerStepCannotPreventFollowingTunCleanupStep",
            ) {
                shutdownTests.hungListenerStepCannotPreventFollowingTunCleanupStep()
            },
            TestCase(
                notificationTests.javaClass.name,
                "staleCleanupCannotDetachANewerGeneration",
            ) {
                notificationTests.staleCleanupCannotDetachANewerGeneration()
            },
            TestCase(
                notificationTests.javaClass.name,
                "notificationStopUsesOneExplicitProcessReceiverAndOneGeneration",
            ) {
                notificationTests.notificationStopUsesOneExplicitProcessReceiverAndOneGeneration()
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
            "missingDataPlaneProofCannotPublishStarted" to permissionTests::missingDataPlaneProofCannotPublishStarted,
            "oneRealHttpsTargetProvesDataPlane" to permissionTests::oneRealHttpsTargetProvesDataPlane,
            "noRealHttpsTargetCannotProveDataPlane" to permissionTests::noRealHttpsTargetCannotProveDataPlane,
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
