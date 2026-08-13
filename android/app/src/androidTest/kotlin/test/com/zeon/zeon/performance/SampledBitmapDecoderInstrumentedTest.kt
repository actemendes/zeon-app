package test.com.zeon.zeon.performance

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import com.mr.flutter.plugin.filepicker.SampledBitmapDecoder
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class SampledBitmapDecoderInstrumentedTest(private val context: Context) {
    fun largeLandscapeIsSampled() {
        withImage("landscape", 4608, 768) { uri ->
            decode(uri, 2048).useBitmap {
                check(it.width <= 2048 && it.height <= 2048)
                check(it.width > it.height)
            }
        }
    }

    fun largePortraitIsSampled() {
        withImage("portrait", 768, 4608) { uri ->
            decode(uri, 2048).useBitmap {
                check(it.width <= 2048 && it.height <= 2048)
                check(it.height > it.width)
            }
        }
    }

    fun smallImageIsNotUpscaled() {
        withImage("small", 128, 96) { uri ->
            decode(uri, 4096).useBitmap {
                check(it.width == 128 && it.height == 96)
            }
        }
    }

    fun squareImageIsSampled() {
        withImage("square", 3072, 3072) { uri ->
            decode(uri, 1024).useBitmap {
                check(it.width <= 1024 && it.height <= 1024)
                check(it.width == it.height)
            }
        }
    }

    fun veryWideImageIsBounded() {
        withImage("wide", 8192, 128) { uri ->
            decode(uri, 2048).useBitmap {
                check(it.width <= 2048 && it.height <= 2048)
            }
        }
    }

    fun veryTallImageIsBounded() {
        withImage("tall", 128, 8192) { uri ->
            decode(uri, 2048).useBitmap {
                check(it.width <= 2048 && it.height <= 2048)
            }
        }
    }

    fun corruptFileIsRejected() {
        expectDecodeFailure(byteArrayOf(1, 2, 3, 4, 5))
    }

    fun emptyByteArrayIsRejected() {
        expectDecodeFailure(byteArrayOf())
    }

    fun truncatedStreamIsRejected() {
        val valid = encodedBitmap(512, 512)
        expectDecodeFailure(valid.copyOf(valid.size / 4))
    }

    fun excessiveDimensionsAreSampledWithoutOverflow() {
        val sample = SampledBitmapDecoder.calculateInSampleSize(
            Int.MAX_VALUE,
            Int.MAX_VALUE,
            4096,
            4096,
        )
        check(sample > 1)
        check(sample and (sample - 1) == 0)
    }

    fun repeatedDecodeKeepsStableDimensions() {
        withImage("repeat", 4096, 1024) { uri ->
            repeat(10) {
                decode(uri, 1024).useBitmap { bitmap ->
                    check(bitmap.width <= 1024 && bitmap.height <= 1024)
                }
            }
        }
    }

    fun parallelDecodeIsIndependent() {
        withImage("parallel", 2048, 1024) { uri ->
            val workers = 4
            val start = CountDownLatch(1)
            val done = CountDownLatch(workers)
            val failure = AtomicReference<Throwable?>()
            val executor = Executors.newFixedThreadPool(workers)
            repeat(workers) {
                executor.execute {
                    try {
                        check(start.await(5, TimeUnit.SECONDS))
                        decode(uri, 512).useBitmap { bitmap ->
                            check(bitmap.width <= 512 && bitmap.height <= 512)
                        }
                    } catch (error: Throwable) {
                        failure.compareAndSet(null, error)
                    } finally {
                        done.countDown()
                    }
                }
            }
            start.countDown()
            check(done.await(30, TimeUnit.SECONDS))
            executor.shutdownNow()
            failure.get()?.let { throw it }
        }
    }

    fun qrLikeImageRemainsPixelSharpWhenSamplingIsNotNeeded() {
        val file = File(context.cacheDir, "bitmap-test-qr.png")
        val source = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        for (y in 0 until 256) {
            for (x in 0 until 256) {
                source.setPixel(x, y, if (((x / 16) + (y / 16)) % 2 == 0) Color.BLACK else Color.WHITE)
            }
        }
        FileOutputStream(file).use { check(source.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        source.recycle()
        try {
            decode(Uri.fromFile(file), 256).useBitmap { decoded ->
                check(decoded.width == 256 && decoded.height == 256)
                check(decoded.getPixel(8, 8) == Color.BLACK)
                check(decoded.getPixel(24, 8) == Color.WHITE)
            }
        } finally {
            file.delete()
        }
    }

    fun notificationOrProfileIconIsNotUpscaled() {
        withImage("icon", 96, 96) { uri ->
            decode(uri, 256).useBitmap {
                check(it.width == 96 && it.height == 96)
                check(it.allocationByteCount <= 96 * 96 * 4)
            }
        }
    }

    private fun decode(uri: Uri, maxDimension: Int): Bitmap =
        SampledBitmapDecoder.decode(context, uri, maxDimension)

    private fun withImage(name: String, width: Int, height: Int, body: (Uri) -> Unit) {
        val file = File(context.cacheDir, "bitmap-test-$name.jpg")
        file.writeBytes(encodedBitmap(width, height))
        try {
            body(Uri.fromFile(file))
        } finally {
            file.delete()
        }
    }

    private fun encodedBitmap(width: Int, height: Int): ByteArray {
        val file = File.createTempFile("bitmap-source-", ".jpg", context.cacheDir)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(32, 96, 160))
        FileOutputStream(file).use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) }
        bitmap.recycle()
        return try {
            file.readBytes()
        } finally {
            file.delete()
        }
    }

    private fun expectDecodeFailure(bytes: ByteArray) {
        val file = File.createTempFile("bitmap-invalid-", ".bin", context.cacheDir)
        file.writeBytes(bytes)
        try {
            var failed = false
            try {
                decode(Uri.fromFile(file), 1024).recycle()
            } catch (_: IOException) {
                failed = true
            }
            check(failed)
        } finally {
            file.delete()
        }
    }

    private inline fun Bitmap.useBitmap(body: (Bitmap) -> Unit) {
        try {
            body(this)
        } finally {
            recycle()
        }
    }
}
