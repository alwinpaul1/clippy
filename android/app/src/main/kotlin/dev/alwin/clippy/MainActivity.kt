package dev.alwin.clippy

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.provider.Settings
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

    private companion object {
        const val SCREENSHOT_PERMISSION_CODE = 4243
    }
    private var screenshotObserver: ContentObserver? = null
    private val handledScreenshots = ArrayDeque<Long>()
    private var permissionResult: MethodChannel.Result? = null

    private val mediaPermission: String
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    /**
     * Photo access as it matters for screenshot auto-sync:
     *  - "granted": full READ_MEDIA_IMAGES — new screenshots are visible.
     *  - "partial": Android 14+ "Select photos" only — new screenshots are
     *    NOT visible, so auto-sync can't work; the user must grant full access.
     *  - "denied": no access.
     */
    private fun photoAccess(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_IMAGES) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                return "granted"
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                ContextCompat.checkSelfPermission(
                    this, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                return "partial"
            }
            return "denied"
        }
        return if (ContextCompat.checkSelfPermission(
                this, Manifest.permission.READ_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            "granted"
        } else {
            "denied"
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        )
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "bgSyncStatus" -> {
                    val id = "$packageName/.ClipboardA11yService"
                    val enabled = (Settings.Secure.getString(
                        contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
                    ) ?: "").split(':').any { it.equals(id, ignoreCase = true) }
                    result.success(
                        mapOf(
                            "enabled" to enabled,
                            "overlay" to Settings.canDrawOverlays(this),
                        ),
                    )
                }
                "openA11ySettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "requestOverlay" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                // Gallery-style image copies put a content:// URI on the
                // clipboard, not bytes — super_clipboard's PNG/JPEG probes
                // all miss it. Resolve the URI ourselves (the focused app is
                // granted read access to clipboard URIs).
                "readClipImage" -> {
                    val cm = getSystemService(CLIPBOARD_SERVICE)
                        as android.content.ClipboardManager
                    val item = cm.primaryClip
                        ?.takeIf { it.itemCount > 0 }?.getItemAt(0)
                    val uri = item?.uri
                    val mime = uri?.let { contentResolver.getType(it) } ?: ""
                    if (uri == null || !mime.startsWith("image/")) {
                        result.success(null)
                    } else {
                        val bytes = try {
                            contentResolver.openInputStream(uri)
                                ?.use { it.readBytes() }
                        } catch (_: Exception) {
                            null
                        }
                        result.success(
                            bytes?.let { mapOf("mime" to mime, "bytes" to it) },
                        )
                    }
                }
                "getInitialText" -> {
                    val shared = extractShare(intent)
                    // Consume it so a controller restart won't re-send the same clip.
                    setIntent(Intent())
                    result.success(shared)
                }
                "startScreenshotWatch" -> {
                    when (photoAccess()) {
                        "granted" -> { watchScreenshots(); result.success("granted") }
                        // Partial: the observer would only ever see user-selected
                        // photos, never new screenshots — report so the UI can
                        // prompt for full access instead of silently doing nothing.
                        "partial" -> result.success("partial")
                        else -> {
                            permissionResult = result
                            ActivityCompat.requestPermissions(
                                this, arrayOf(mediaPermission), SCREENSHOT_PERMISSION_CODE,
                            )
                        }
                    }
                }
                // Deep-link to Clippy's app settings so the user can switch from
                // "Select photos" to "Allow all" (can't be upgraded in-app).
                "openPhotoSettings" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", packageName, null),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Direct Vibrator haptics: Samsung gates View.performHapticFeedback
        // (all of Flutter's HapticFeedback.*) behind system touch-vibration
        // settings, so app haptics silently die. VibrationEffect doesn't.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "clippy/haptics",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "tick" -> { vibrate(25, 120); result.success(null) }
                "thump" -> { vibrate(55, 255); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun vibrate(ms: Long, amplitude: Int) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager)
                .defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
        vibrator.vibrate(VibrationEffect.createOneShot(ms, amplitude))
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != SCREENSHOT_PERMISSION_CODE) return
        val status = photoAccess()
        if (status == "granted") watchScreenshots()
        permissionResult?.success(status)
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
