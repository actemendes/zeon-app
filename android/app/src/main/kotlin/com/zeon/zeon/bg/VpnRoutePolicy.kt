package com.zeon.zeon.bg

/** Keep the Android route table consistent with the address families exposed by the core. */
internal fun shouldInstallIpv6Routes(hasInet6Address: Boolean): Boolean = hasInet6Address
