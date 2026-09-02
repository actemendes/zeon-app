package com.zeon.zeon.bg

import android.net.Network
import android.os.Build
import com.zeon.zeon.Application
import com.hiddify.core.libbox.InterfaceUpdateListener
import com.zeon.zeon.constant.Bugs


import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import java.net.NetworkInterface
import java.util.concurrent.ConcurrentHashMap

object DefaultNetworkMonitor {

    private class MonitorOwner(
        val generation: Long,
        val onNetworkChanged: (Network?) -> Unit,
    )

    private val ownerLock = Any()
    private val owners = ConcurrentHashMap<Long, MonitorOwner>()
    @Volatile
    private var currentOwner: MonitorOwner? = null
    @Volatile
    var defaultNetwork: Network? = null
    @Volatile
    private var listener: InterfaceUpdateListener? = null

    suspend fun start(
        generation: Long,
        onNetworkChanged: (Network?) -> Unit = {},
    ) {
        val owner = MonitorOwner(generation, onNetworkChanged)
        synchronized(ownerLock) {
            owners[generation] = owner
            currentOwner = owner
        }
        DefaultNetworkListener.start(owner) { network ->
            if (currentOwner === owner) {
                defaultNetwork = network
                checkDefaultInterfaceUpdate(network)
                owner.onNetworkChanged(network)
            }
        }
        val resolvedNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Application.connectivity.activeNetwork
        } else {
            DefaultNetworkListener.get()
        }
        val remainsCurrent = synchronized(ownerLock) {
            if (currentOwner === owner && owners[generation] === owner) {
                defaultNetwork = resolvedNetwork
                true
            } else {
                false
            }
        }
        if (!remainsCurrent) {
            DefaultNetworkListener.stop(owner)
        } else {
            owner.onNetworkChanged(resolvedNetwork)
        }
    }

    suspend fun stop(generation: Long) {
        val owner = synchronized(ownerLock) {
            val removed = owners.remove(generation) ?: return
            if (currentOwner === removed) {
                currentOwner = null
                defaultNetwork = null
            }
            removed
        }
        // Each generation has a distinct actor key. A delayed Stop for an old
        // generation therefore cannot unregister a newer monitor owner.
        DefaultNetworkListener.stop(owner)
    }

    suspend fun require(): Network {
        val network = defaultNetwork
        if (network != null) {
            return network
        }
        return DefaultNetworkListener.get()
    }

    fun setListener(listener: InterfaceUpdateListener?) {
        this.listener = listener
        checkDefaultInterfaceUpdate(defaultNetwork)
    }

    fun clearListener(generation: Long) {
        val cleared = synchronized(ownerLock) {
            if (currentOwner?.generation != generation) {
                false
            } else {
                listener = null
                true
            }
        }
        if (cleared) {
            checkDefaultInterfaceUpdate(defaultNetwork)
        }
    }

    internal fun currentGenerationForTesting(): Long = currentOwner?.generation ?: 0L

    private fun checkDefaultInterfaceUpdate(newNetwork: Network?) {
        val listener = listener ?: return
        if (newNetwork != null) {
            val interfaceName =
                (Application.connectivity.getLinkProperties(newNetwork) ?: return).interfaceName
            for (times in 0 until 10) {
                var interfaceIndex: Int
                try {
                    interfaceIndex = NetworkInterface.getByName(interfaceName).index
                } catch (e: Exception) {
                    Thread.sleep(100)
                    continue
                }
                listener.updateDefaultInterface(interfaceName, interfaceIndex, false, false)
            }
        } else {
            listener.updateDefaultInterface("", -1, false, false)
        }
    }
}
