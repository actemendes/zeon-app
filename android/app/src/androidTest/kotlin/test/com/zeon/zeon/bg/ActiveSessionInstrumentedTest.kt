package test.com.zeon.zeon.bg

import android.os.ParcelFileDescriptor
import com.hiddify.core.libbox.PlatformInterface
import com.zeon.zeon.bg.ActiveSession
import com.zeon.zeon.bg.TunDescriptorOwner
import com.zeon.zeon.bg.VpnSessionCoordinator
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import java.lang.reflect.Proxy

class ActiveSessionInstrumentedTest {
    suspend fun teardownOrderIsStableAndCloseIsIdempotent() {
        val generation = VpnSessionCoordinator.next("active_session_order")
        val tunOwner = TunDescriptorOwner()
        val descriptor = descriptor()
        tunOwner.open(generation, descriptor)
        val session = ActiveSession(generation, platform(), tunOwner)
        val order = mutableListOf<String>()

        coroutineScope {
            val first = async { close(session, order) }
            val second = async { close(session, order) }
            first.await()
            second.await()
        }

        check(order == listOf("clients", "core", "server", "platform", "network")) {
            "unexpected teardown order: $order"
        }
        check(!descriptor.fileDescriptor.valid())
        check(!session.acceptsOperations())
    }

    private suspend fun close(session: ActiveSession, order: MutableList<String>) {
        session.close(
            reason = "test",
            closeCommandClientsAndListeners = { order += "clients" },
            stopCore = { order += "core" },
            closeCommandServer = { order += "server" },
            closePlatform = { order += "platform" },
            clearNetwork = { order += "network" },
        )
    }

    private fun platform(): PlatformInterface {
        return Proxy.newProxyInstance(
            PlatformInterface::class.java.classLoader,
            arrayOf(PlatformInterface::class.java),
        ) { _, method, _ ->
            when (method.returnType) {
                java.lang.Boolean.TYPE -> false
                java.lang.Integer.TYPE -> 0
                java.lang.Long.TYPE -> 0L
                else -> null
            }
        } as PlatformInterface
    }

    private fun descriptor(): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        pipe[1].close()
        return pipe[0]
    }
}
