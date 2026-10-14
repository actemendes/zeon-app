package test.com.zeon.zeon.bg

import com.zeon.zeon.OptionalActivityRequest
import com.zeon.zeon.completeCoreSetup
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

class PlatformCompatibilityInstrumentedTest {
    private class Reply : MethodChannel.Result {
        val successes = mutableListOf<Any?>()
        val errors = mutableListOf<String>()
        override fun success(result: Any?) { successes += result }
        override fun error(code: String, message: String?, details: Any?) {
            check(message?.contains("private-fixture") != true)
            check(details == null)
            errors += code
        }
        override fun notImplemented() = error("unexpected notImplemented")
    }

    suspend fun failedCoreSetupSettlesFlutterInsteadOfHanging() {
        val reply = Reply()
        completeCoreSetup(reply) {
            delay(1)
            error("private-fixture")
        }
        check(reply.errors == listOf("core_setup_failed"))
        check(reply.successes.isEmpty())
    }

    suspend fun cancelledCoreSetupSettlesAndPreservesCancellation() {
        val reply = Reply()
        val cancellation = CancellationException("private-fixture")
        val thrown = runCatching { completeCoreSetup(reply) { throw cancellation } }.exceptionOrNull()
        check(thrown === cancellation)
        check(reply.errors == listOf("core_setup_cancelled"))
        check(reply.successes.isEmpty())
    }

    suspend fun missingNativeSymbolSettlesFlutterInsteadOfHanging() {
        val reply = Reply()
        completeCoreSetup(reply) { throw UnsatisfiedLinkError("private-fixture") }
        check(reply.errors == listOf("core_setup_failed"))
        check(reply.successes.isEmpty())
    }

    suspend fun successfulCoreSetupRepliesExactlyOnce() {
        val reply = Reply()
        completeCoreSetup(reply) { delay(1) }
        check(reply.successes == listOf(""))
        check(reply.errors.isEmpty())
    }

    suspend fun setupReplyDeliveryFailureDoesNotSendSecondReply() {
        var deliveries = 0
        val reply = object : MethodChannel.Result {
            override fun success(result: Any?) { deliveries++; error("delivery failed") }
            override fun error(code: String, message: String?, details: Any?) { deliveries++ }
            override fun notImplemented() = error("unexpected notImplemented")
        }
        check(runCatching { completeCoreSetup(reply) {} }.isFailure)
        check(deliveries == 1)
    }

    fun missingSettingsActivitySettlesFalse() {
        val request = OptionalActivityRequest()
        val reply = Reply()
        request.begin(reply) { false }
        request.complete(true)
        check(reply.successes == listOf(false))
    }

    fun rejectedSettingsIntentSettlesFalse() {
        val request = OptionalActivityRequest()
        val reply = Reply()
        request.begin(reply) { throw SecurityException("private-fixture") }
        check(reply.successes == listOf(false))
    }

    fun activityDetachSettlesOnceAndAllowsRetry() {
        val request = OptionalActivityRequest()
        val first = Reply()
        request.begin(first) { true }
        request.complete(false)
        request.complete(true)
        check(first.successes == listOf(false))
        val retry = Reply()
        request.begin(retry) { true }
        request.complete(true)
        check(retry.successes == listOf(true))
    }

    fun concurrentSettingsRequestDoesNotLoseFirstReply() {
        val request = OptionalActivityRequest()
        val first = Reply()
        val duplicate = Reply()
        request.begin(first) { true }
        request.begin(duplicate) { error("duplicate must not launch") }
        request.complete(true)
        check(first.successes == listOf(true))
        check(duplicate.successes == listOf(false))
    }
}
