package com.zeon.zeon.bg

import com.hiddify.core.libbox.PlatformInterface
import com.hiddify.core.libbox.TunOptions

/** A per-core PlatformInterface whose callback ownership never changes. */
class GenerationBoundPlatformInterface(
    val ownerGeneration: Long,
    delegate: PlatformInterface,
    private val openTunForOwner: (Long, TunOptions) -> Int,
    private val controlSocketForOwner: (Long, Int) -> Unit,
) : PlatformInterface by delegate {
    override fun openTun(options: TunOptions): Int = openTunForOwner(ownerGeneration, options)

    override fun autoDetectInterfaceControl(fd: Int) = controlSocketForOwner(ownerGeneration, fd)
}
