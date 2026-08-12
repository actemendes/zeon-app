package test.com.zeon.zeon.bg

import com.zeon.zeon.bg.shouldInstallIpv6Routes

class VpnRoutePolicyInstrumentedTest {
    fun ipv4OnlyTunDoesNotInstallIpv6Routes() {
        check(!shouldInstallIpv6Routes(hasInet6Address = false))
    }

    fun dualStackTunInstallsIpv6Routes() {
        check(shouldInstallIpv6Routes(hasInet6Address = true))
    }
}
