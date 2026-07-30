package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.VpnSessionPhase
import com.zeon.zeon.bg.VpnSessionSnapshot

class VpnSessionSnapshotInstrumentedTest {
    private fun snapshot(
        phase: VpnSessionPhase,
        ready: Boolean,
        outbound: String = if (ready) "opaque" else "",
    ) = VpnSessionSnapshot(
        generation = 10L,
        runtimeEpoch = "test",
        sequenceNumber = 1L,
        snapshotVersion = 1L,
        phase = phase,
        coreReady = ready,
        coreStarted = ready,
        commandEndpointReady = ready,
        tunnelReady = ready,
        protectSucceeded = ready,
        platformVpnValidated = ready,
        selectedOutboundId = outbound,
    )

    fun connectedRequiresEveryGate() {
        check(!snapshot(VpnSessionPhase.CONNECTED, ready = false).provesConnected())
        check(!snapshot(VpnSessionPhase.CONNECTED, ready = true, outbound = "").provesConnected())
        check(snapshot(VpnSessionPhase.CONNECTED, ready = true).provesConnected())
    }

    fun nonConnectedPhaseCannotPassTheGate() {
        check(!snapshot(VpnSessionPhase.VERIFYING, ready = true).provesConnected())
        check(!snapshot(VpnSessionPhase.STOPPING, ready = true).provesConnected())
    }
}
