package dev.alwin.clippy

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
 *
 * Plus the screenshot auto-sync (needs the photo-read permission): a
 * MediaStore observer that emits each new screenshot through the same
 * "onShared" callback, so Dart consumes it exactly like a shared image.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "clippy/share"
    private var channel: MethodChannel? = null
    private var screenshotObserver: ContentObserver? = null
    private val handledScreenshots = ArrayDeque<Long>()
    private var permissionResult: MethodChannel.Result? = null

    private val mediaPermission: String
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        )
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val shared = extractShare(intent)
                    // Consume it so a controller restart won't re-send the same clip.
                    setIntent(Intent())
                    result.success(shared)
                }
                "startScreenshotWatch" -> {
                    if (ContextCompat.checkSelfPermission(this, mediaPermission) ==
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        watchScreenshots()
                        result.success(true)
                    } else {
                        permissionResult = result
                        ActivityCompat.requestPermissions(
                            this, arrayOf(mediaPermission), SCREENSHOT_PERMISSION_CODE,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != SCREENSHOT_PERMISSION_CODE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) watchScreenshots()
        permissionResult?.success(granted)
        permissionResult = null
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        screenshotObserver?.let {
            applicationContext.contentResolver.unregisterContentObserver(it)
        }
        screenshotObserver = null
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Watches MediaStore for new images and emits ones that look like
     * screenshots. Registered on the application context so it keeps firing
     * while Clippy is backgrounded (as long as the process is alive).
     */
    private fun watchScreenshots() {
        if (screenshotObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                uri ?: return
                // Item URIs only — collection-level change events carry no ID.
                uri.lastPathSegment?.toLongOrNull() ?: return
                Thread { emitIfNewScreenshot(uri) }.start()
            }
        }
        applicationContext.contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer,
        )
        screenshotObserver = observer
    }

    private fun emitIfNewScreenshot(uri: Uri) {
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DATE_ADDED,
        )
        val resolver = applicationContext.contentResolver
        val cursor = try {
            // Pending (still-being-written) rows are hidden from this query;
            // MediaStore fires another onChange once the file is finalized.
            resolver.query(uri, projection, null, null, null)
        } catch (_: Exception) {
            null
        } ?: return
        cursor.use { c ->
            if (!c.moveToFirst()) return
            val id = c.getLong(0)
            val name = c.getString(1) ?: ""
            val path = c.getString(2) ?: ""
            val added = c.getLong(3)
            val looksLikeShot = path.contains("Screenshot", ignoreCase = true) ||
                name.startsWith("Screenshot", ignoreCase = true)
            if (!looksLikeShot) return
            // Fresh rows only — MediaStore also fires for edits and rescans.
            if (System.currentTimeMillis() / 1000 - added > 20) return
            synchronized(handledScreenshots) {
                if (handledScreenshots.contains(id)) return
                handledScreenshots.addLast(id)
                if (handledScreenshots.size > 8) handledScreenshots.removeFirst()
            }
            val bytes = try {
                resolver.openInputStream(uri)?.use { it.readBytes() }
            } catch (_: Exception) {
                null
            } ?: return
            val mime = resolver.getType(uri) ?: "image/png"
            Handler(Looper.getMainLooper()).post {
                channel?.invokeMethod(
                    "onShared",
                    mapOf("kind" to "image", "mime" to mime, "bytes" to bytes),
                )
            }
        }
    }

    private companion object {
        const val SCREENSHOT_PERMISSION_CODE = 4243
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
