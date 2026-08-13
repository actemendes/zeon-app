package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.StartPermissionRequestCoordinator
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class StartPermissionRequestCoordinatorInstrumentedTest {
    private class Harness(seed: Long = 700L) {
        var current = seed
        val outcomes = mutableListOf<StartPermissionRequestCoordinator.Outcome>()
        val events = mutableListOf<String>()
        val gate = StartPermissionRequestCoordinator(
            currentGeneration = { current },
            event = { name, generation, details -> events += "$name/$generation/$details" },
        )

        fun begin(
            generation: Long = current,
            notificationGranted: Boolean,
            vpnGranted: Boolean,
        ) = gate.begin(
            StartPermissionRequestCoordinator.Request(
                generation = generation,
                startAfterGrant = false,
                callback = { outcomes += it },
            ),
            notificationGranted = notificationGranted,
            vpnGranted = vpnGranted,
        )
    }

    fun bothPermissionsMissingAreSerializedNotificationThenVpn() {
        val h = Harness()
        check(h.begin(notificationGranted = false, vpnGranted = false) == notificationAction)
        check(
            h.gate.completeNotification(
                resultGranted = true,
                notificationGranted = true,
                vpnGranted = false,
            ) == vpnAction,
        )
        check(
            h.gate.completeVpn(
                resultGranted = true,
                notificationGranted = true,
                vpnGranted = true,
            ) == noAction,
        )
        check(h.outcomes == listOf(granted))
    }

    fun notificationGrantedThenVpnGrantedCompletesOneAttempt() =
        bothPermissionsMissingAreSerializedNotificationThenVpn()

    fun vpnAlreadyGrantedWaitsOnlyForNotification() {
        val h = Harness()
        check(h.begin(notificationGranted = false, vpnGranted = true) == notificationAction)
        check(
            h.gate.completeNotification(
                resultGranted = true,
                notificationGranted = true,
                vpnGranted = true,
            ) == noAction,
        )
        check(h.outcomes == listOf(granted))
    }

    fun notificationDeniedTerminatesAttempt() {
        val h = Harness()
        h.begin(notificationGranted = false, vpnGranted = false)
        h.gate.completeNotification(
            resultGranted = false,
            notificationGranted = false,
            vpnGranted = false,
        )
        check(h.outcomes == listOf(StartPermissionRequestCoordinator.Outcome.NotificationDenied))
    }

    fun vpnDeniedTerminatesAttempt() {
        val h = Harness()
        h.begin(notificationGranted = true, vpnGranted = false)
        h.gate.completeVpn(
            resultGranted = false,
            notificationGranted = true,
            vpnGranted = false,
        )
        check(h.outcomes == listOf(StartPermissionRequestCoordinator.Outcome.VpnDenied))
    }

    fun closedDialogIsDenied() = vpnDeniedTerminatesAttempt()

    fun delayedCallbacksKeepTheOwningGeneration() {
        val h = Harness()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val done = CountDownLatch(1)
        check(h.begin(notificationGranted = false, vpnGranted = true) == notificationAction)
        val worker = Thread {
            entered.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            h.gate.completeNotification(true, notificationGranted = true, vpnGranted = true)
            done.countDown()
        }
        worker.start()
        check(entered.await(2, TimeUnit.SECONDS))
        check(h.outcomes.isEmpty())
        release.countDown()
        check(done.await(2, TimeUnit.SECONDS))
        worker.join()
        check(h.outcomes == listOf(granted))
    }

    fun duplicateCallbackCannotCompleteTwice() {
        val h = Harness()
        h.begin(notificationGranted = true, vpnGranted = false)
        h.gate.completeVpn(true, notificationGranted = true, vpnGranted = true)
        h.gate.completeVpn(true, notificationGranted = true, vpnGranted = true)
        check(h.outcomes == listOf(granted))
        check(h.events.any { "duplicate_or_unowned_result" in it })
    }

    fun stopDuringDialogCancelsPendingAttempt() {
        val h = Harness()
        h.begin(notificationGranted = false, vpnGranted = false)
        h.current++
        h.gate.cancelAll("stop")
        check(h.outcomes == listOf(stale))
        h.gate.completeNotification(true, notificationGranted = true, vpnGranted = false)
        check(h.outcomes == listOf(stale))
    }

    fun processRecreationCancelsOldDialogOwnership() {
        val h = Harness()
        h.begin(notificationGranted = false, vpnGranted = false)
        h.gate.cancelAll("activity_destroyed")
        check(h.outcomes == listOf(stale))
        h.current++
        check(h.begin(notificationGranted = true, vpnGranted = true) == noAction)
        check(h.outcomes == listOf(stale, granted))
    }

    fun staleDialogResultReevaluatesButDoesNotCompleteNewGenerationDirectly() {
        val h = Harness()
        h.begin(notificationGranted = false, vpnGranted = false)
        val oldGeneration = h.current
        h.current++
        check(h.begin(notificationGranted = true, vpnGranted = false) == noAction)
        check(h.outcomes == listOf(stale))

        check(
            h.gate.completeNotification(
                resultGranted = true,
                notificationGranted = true,
                vpnGranted = false,
            ) == vpnAction,
        )
        check(h.outcomes == listOf(stale))
        h.gate.completeVpn(true, notificationGranted = true, vpnGranted = true)
        check(h.outcomes == listOf(stale, granted))
        check(h.events.any { it.startsWith("permission_result_ignored_stale/$oldGeneration/") })
    }

    fun successfulFirstStartNeedsNoSecondBegin() {
        val h = Harness()
        var beginCount = 0
        beginCount++
        h.begin(notificationGranted = false, vpnGranted = false)
        h.gate.completeNotification(true, notificationGranted = true, vpnGranted = false)
        h.gate.completeVpn(true, notificationGranted = true, vpnGranted = true)
        check(beginCount == 1)
        check(h.outcomes == listOf(granted))
        check(h.events.count { it.startsWith("permission_request_started/") } == 2)
    }

    private companion object {
        val noAction = StartPermissionRequestCoordinator.Action.None
        val notificationAction = StartPermissionRequestCoordinator.Action.RequestNotification
        val vpnAction = StartPermissionRequestCoordinator.Action.RequestVpn
        val granted = StartPermissionRequestCoordinator.Outcome.Granted
        val stale = StartPermissionRequestCoordinator.Outcome.Stale
    }
}
