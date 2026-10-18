package dev.alwin.clippy

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * On-device image understanding for search ("clippy/vision"): the text in a
 * screenshot (ML Kit OCR) and what a photo shows (ML Kit image labels). Both
 * models are BUNDLED in the APK, so this works offline and without Google
 * Play services. Nothing leaves the device; the image arrives already
 * decrypted from Dart and the result goes straight back.
 */
object ClipVision {
    // One worker: images are analysed one at a time, off the main thread.
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }
    private val labeler by lazy {
        ImageLabeling.getClient(
            ImageLabelerOptions.Builder().setConfidenceThreshold(0.6f).build(),
        )
    }

    // Longest side handed to the models. OCR needs readable glyphs, not the
    // full 4K bitmap; this caps memory on a big photo.
    private const val MAX_SIDE = 2560

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "clippy/vision").setMethodCallHandler { call, result ->
            if (call.method != "analyze") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("bytes")
            if (bytes == null) {
                result.error("args", "bytes missing", null)
                return@setMethodCallHandler
            }
            worker.execute {
                val out = try {
                    analyze(bytes)
                } catch (t: Throwable) {
                    null
                }
                main.post {
                    if (out == null) result.error("vision", "analysis failed", null) else result.success(out)
                }
            }
        }
    }

    private fun analyze(bytes: ByteArray): Map<String, Any> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_SIDE) sample *= 2
        val bitmap = BitmapFactory.decodeByteArray(
            bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: return mapOf("text" to "", "labels" to emptyList<String>())
        try {
            val image = InputImage.fromBitmap(bitmap, 0)
            val text = Tasks.await(recognizer.process(image)).text
            val labels = Tasks.await(labeler.process(image)).map { it.text.lowercase() }
            return mapOf("text" to text, "labels" to labels)
        } finally {
            bitmap.recycle()
        }
    }
}
