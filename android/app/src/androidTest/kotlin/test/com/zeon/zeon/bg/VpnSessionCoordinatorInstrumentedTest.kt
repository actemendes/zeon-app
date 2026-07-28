package test.com.zeon.zeon.bg

import android.test.InstrumentationTestCase
import com.zeon.zeon.bg.VpnSessionCoordinator

@Suppress("DEPRECATION")
class VpnSessionCoordinatorInstrumentedTest : InstrumentationTestCase() {
    fun testGenerationIsStrictlyMonotonic() {
        val first = VpnSessionCoordinator.next("instrumented_first")
        val second = VpnSessionCoordinator.next("instrumented_second")

        assertTrue(second > first)
        assertTrue(VpnSessionCoordinator.isCurrent(second))
        assertFalse(VpnSessionCoordinator.isCurrent(first))
    }

    fun testStaleExternalGenerationCannotReplaceCurrent() {
        val current = VpnSessionCoordinator.next("instrumented_current")
        val accepted = VpnSessionCoordinator.accept(current - 1, "instrumented_stale")

        assertEquals(current, accepted)
        assertEquals(current, VpnSessionCoordinator.current())
    }
}
