package dev.alwin.clippy

import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Android's "Send to Clippy" entry points into Flutter — no special
 * permissions:
 *  - ACTION_PROCESS_TEXT: the "Clippy" item in the text-selection popup.
 *  - ACTION_SEND (text): "Clippy" in the Share sheet (returns a String).
 *  - ACTION_SEND (image): "Clippy" in the Share sheet for images (returns a
 *    map {kind:"image", mime, bytes} — bytes cross as a Uint8List).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "clippy/share"
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        )
        channel!!.setMethodCallHandler { call, result ->
            if (call.method == "getInitialText") {
                val shared = extractShare(intent)
                // Consume it so a controller restart won't re-send the same clip.
                setIntent(Intent())
                result.success(shared)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val shared = extractShare(intent)
        if (shared != null) channel?.invokeMethod("onShared", shared)
    }

    /** Returns a String (text) or a Map (image), or null. */
    private fun extractShare(intent: Intent?): Any? {
        intent ?: return null
        return when (intent.action) {
            Intent.ACTION_PROCESS_TEXT ->
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
                    ?.toString()?.takeIf { it.isNotBlank() }
            Intent.ACTION_SEND -> {
                val type = intent.type ?: return null
                when {
                    type == "text/plain" ->
                        intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
                    type.startsWith("image/") -> extractImage(intent, type)
                    else -> null
                }
            }
            else -> null
        }
    }

    private fun extractImage(intent: Intent, type: String): Map<String, Any>? {
        val uri = IntentCompat.getParcelableExtra(
            intent, Intent.EXTRA_STREAM, Uri::class.java,
        ) ?: return null
        val bytes = try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (_: Exception) {
            null
        } ?: return null
        val mime = contentResolver.getType(uri) ?: type
        return mapOf("kind" to "image", "mime" to mime, "bytes" to bytes)
    }
}
