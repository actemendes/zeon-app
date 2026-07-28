package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.VpnSessionCoordinator

class VpnSessionCoordinatorInstrumentedTest {
    fun generationIsStrictlyMonotonic() {
        val first = VpnSessionCoordinator.next("instrumented_first")
        val second = VpnSessionCoordinator.next("instrumented_second")

        check(second > first)
        check(VpnSessionCoordinator.isCurrent(second))
        check(!VpnSessionCoordinator.isCurrent(first))
    }

    fun staleExternalGenerationCannotReplaceCurrent() {
        val current = VpnSessionCoordinator.next("instrumented_current")
        val accepted = VpnSessionCoordinator.accept(current - 1, "instrumented_stale")

        check(current == accepted)
        check(current == VpnSessionCoordinator.current())
    }
}
