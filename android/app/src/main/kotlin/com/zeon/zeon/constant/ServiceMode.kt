package com.zeon.zeon.constant

object ServiceMode {
    const val VPN = "vpn"

    fun canonicalize(@Suppress("UNUSED_PARAMETER") storedMode: String?): String = VPN
}
