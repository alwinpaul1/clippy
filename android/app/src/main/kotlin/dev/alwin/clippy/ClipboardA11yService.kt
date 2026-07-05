package dev.alwin.clippy

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Context
import android.database.ContentObserver
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import java.io.File

/**
 * Background clipboard capture without being the keyboard, via an
 * AccessibilityService. An enabled AS keeps a privileged, long-lived process
 * (survives clear-from-recents) and its clipboard listener may fire in the
 * background where a normal app's doesn't. If the listener alone can't read
 * the content, we fall back to the 1px focus-trick overlay to grab focus for
 * one frame and read.
 *
 * Captured text is queued to filesDir/clip_queue, which the app / foreground
 * service drains and syncs (engine dedup absorbs repeats).
 */
class ClipboardA11yService : AccessibilityService() {
    private var lastText: String? = null
    private var lastImageKey: String? = null
    private var busy = false
    private val main = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    // Screenshots taken while the app is swiped-away: the activity's MediaStore
    // observer died with it, and Directory.watch on external storage's FUSE
    // mount doesn't deliver inotify — but THIS service's process survives, so a
    // ContentObserver here catches new screenshots and queues them to filesDir
    // (where the Dart queue-watcher's inotify IS reliable) for instant sync.
    private var shotObserver: ContentObserver? = null
    private val handledShots = ArrayDeque<Long>()
    private val startedAtSec = System.currentTimeMillis() / 1000

    override fun onServiceConnected() {
        super.onServiceConnected()
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.addPrimaryClipChangedListener {
            pending?.let { main.removeCallbacks(it) }
            val r = Runnable { onClipChanged(cm) }
            pending = r
            main.postDelayed(r, 120)
        }
        watchScreenshots()
    }

    private fun watchScreenshots() {
        if (shotObserver != null) return
        val observer = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                uri ?: return
                uri.lastPathSegment?.toLongOrNull() ?: return // item URIs only
                // Delay the read: MediaStore inserts the row before the file
                // bytes are flushed, so an immediate read gets a partial/empty
                // file. If it's still not ready, an empty read leaves the id
                // unmarked and a later onChange retries.
                main.postDelayed({ Thread { queueIfNewScreenshot(uri) }.start() }, 600)
            }
        }
        try {
            applicationContext.contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer,
            )
            shotObserver = observer
        } catch (_: Exception) {
            // No photo permission yet — the FGS folder-scan tick still covers it.
        }
    }

    private fun queueIfNewScreenshot(uri: Uri) {
        val resolver = applicationContext.contentResolver
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DATE_ADDED,
        )
        val cursor = try {
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
            // A real screenshot's DISPLAY_NAME starts with "Screenshot";
            // Samsung also emits a "thumbnail_Screenshot…" whose PATH contains
            // "Screenshot" — exclude it so we sync the full image, not the 13KB
            // thumbnail.
            val isThumb = name.startsWith("thumbnail", ignoreCase = true) ||
                path.contains(".thumbnails", ignoreCase = true)
            val looksLikeShot = !isThumb &&
                name.startsWith("Screenshot", ignoreCase = true)
            if (!looksLikeShot) return
            // Fresh only: taken after we started AND within the last 20s (skip
            // edits/rescans of old files, and never the phone's whole history).
            val nowSec = System.currentTimeMillis() / 1000
            if (added < startedAtSec || nowSec - added > 20) return
            synchronized(handledShots) {
                if (handledShots.contains(id)) return
            }
            val bytes = try {
                resolver.openInputStream(uri)?.use { it.readBytes() }
            } catch (_: Exception) {
                null
            }
            // Mark handled only after a real read — if the file wasn't flushed
            // yet, let a later onChange retry instead of dropping it forever.
            if (bytes == null || bytes.isEmpty()) return
            synchronized(handledShots) {
                if (handledShots.contains(id)) return
                handledShots.addLast(id)
                if (handledShots.size > 8) handledShots.removeFirst()
            }
            val ext = when (resolver.getType(uri)) {
                "image/jpeg" -> "jpg"
                "image/webp" -> "webp"
                else -> "png"
            }
            emitImage(bytes, ext)
        }
    }

    private var lastPoll = 0L
    private var trailing: Runnable? = null

    // Lowercased "copied to clipboard" toast wording for the locales we can
    // reasonably expect. Matching keeps the trigger off unrelated system toasts
    // (e.g. "Screenshot saved") so it doesn't flicker. Other languages fall
    // through to the selection-based trigger and the app-open read; extend as
    // needed.
    private val copyToastWords = listOf(
        "copied", "kopiert", "copiado", "copié", "copie",
        "copiato", "gekopieerd", "copiat",
    )

    private fun isCopyToast(text: List<CharSequence>): Boolean {
        val joined = text.joinToString(" ").lowercase()
        return copyToastWords.any { joined.contains(it) }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // On One UI the background clipboard listener is dead, so use
        // accessibility events as the "user just copied" trigger, then read the
        // clipboard via the focus-trick overlay.
        val t = event?.eventType ?: return
        // PRIMARY trigger: copying text posts a system Toast ("Copied.") from
        // com.android.systemui. It's the ONLY signal a copy from Chrome's address
        // bar (an EditText) produces — Chrome emits no selection-change or click
        // we can see there. It also fires only on a real copy, so unlike the
        // selection-based path below it never flickers on typing or dragging. We
        // read only the Toast text to confirm it's a copy (never screen content),
        // then read the clipboard.
        if (t == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED) {
            if (event.packageName?.toString() == "com.android.systemui" &&
                isCopyToast(event.text)) {
                attemptRead()
            }
            return
        }
        // SECONDARY trigger (apps whose copy does NOT toast): some apps' Copy is a
        // real TYPE_VIEW_CLICKED; others COLLAPSE the selection
        // (TEXT_SELECTION_CHANGED, from == to). A RANGED selection (from != to) is
        // a drag — skip it. Typing (IME / EditText) is skipped.
        val isSel = t == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED
        val isClick = t == AccessibilityEvent.TYPE_VIEW_CLICKED
        if (!isSel && !isClick) return
        val pkg = event.packageName?.toString().orEmpty().lowercase()
        val cls = event.className?.toString().orEmpty()
        val fromIme = pkg.contains("inputmethod") || pkg.contains("keyboard") ||
            pkg.contains("honeyboard") || pkg.contains("gboard") ||
            pkg.contains("swiftkey")
        if (fromIme || cls.contains("EditText")) return
        if (isSel && event.fromIndex != event.toIndex) return
        val now = System.currentTimeMillis()
        val wait = 800 - (now - lastPoll)
        if (wait <= 0) {
            lastPoll = now
            attemptRead()
            // A Copy tap's click event can arrive BEFORE the system commits
            // the clipboard — one follow-up read catches the fresh content.
            scheduleTrailing(600)
        } else if (trailing == null) {
            scheduleTrailing(wait)
        }
    }

    private fun scheduleTrailing(delayMs: Long) {
        if (trailing != null) return
        val r = Runnable {
            trailing = null
            lastPoll = System.currentTimeMillis()
            attemptRead()
        }
        trailing = r
        main.postDelayed(r, delayMs)
    }

    private fun attemptRead() {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        if (capture(cm)) return
        focusTrickRead(cm)
    }

    override fun onInterrupt() {}

    private fun onClipChanged(cm: ClipboardManager) {
        // 1) Direct read — does the AS context have clipboard access in bg?
        if (capture(cm)) return
        // 2) Fallback: focus-trick overlay (needs SYSTEM_ALERT_WINDOW).
        focusTrickRead(cm)
    }

    // Read whatever's on the clipboard and queue it. Image first: a Gallery-style
    // copy is a bare content:// image URI (coerceToText would yield the useless
    // "content://…" string), so resolve the bytes and NEVER fall through to text
    // for an image clip. Returns true once something was captured.
    private fun capture(cm: ClipboardManager): Boolean {
        val item = try {
            cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        } catch (_: Exception) {
            null
        } ?: return false
        val uri = item.uri
        if (uri != null) {
            val mime = try {
                contentResolver.getType(uri)
            } catch (_: Exception) {
                null
            } ?: ""
            if (mime.startsWith("image/")) return emitClipImage(uri, mime)
        }
        val text = try {
            item.coerceToText(this)?.toString()?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        } ?: return false
        emit(text)
        return true
    }

    // Resolve a clipboard image URI to bytes and queue it. The open can fail with
    // SecurityException if the background service isn't granted read access to the
    // source app's URI — the caller then falls back to the focus-trick, which puts
    // us in focus for a frame so the grant applies.
    private fun emitClipImage(uri: Uri, mime: String): Boolean {
        return try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null || bytes.isEmpty()) {
                Log.w("ClippyImg", "clip image empty/unreadable: $uri")
                return false
            }
            val key = "$uri:${bytes.size}"
            if (key == lastImageKey) return true // already captured this copy
            lastImageKey = key
            val ext = when (mime) {
                "image/jpeg" -> "jpg"
                "image/webp" -> "webp"
                "image/gif" -> "gif"
                else -> "png"
            }
            Log.i("ClippyImg", "captured clip image ${bytes.size}B $mime")
            emitImage(bytes, ext)
            true
        } catch (e: Exception) {
            Log.w("ClippyImg", "clip image read failed: ${e.javaClass.simpleName} ${e.message}")
            false
        }
    }

    private fun focusTrickRead(cm: ClipboardManager) {
        if (busy) return
        busy = true
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val view = View(this)
        val params = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        )
        var done = false
        fun finish() {
            if (done) return; done = true; busy = false
            try { wm.removeView(view) } catch (_: Exception) {}
        }
        view.viewTreeObserver.addOnWindowFocusChangeListener { hasFocus ->
            if (!hasFocus) return@addOnWindowFocusChangeListener
            capture(cm)
            finish()
        }
        try {
            wm.addView(view, params)
        } catch (_: Exception) {
            finish()
            return
        }
        main.postDelayed({ finish() }, 2000)
    }

    private fun emit(text: String) {
        if (text == lastText) return
        lastText = text
        try {
            val dir = File(filesDir, "clip_queue")
            dir.mkdirs()
            File(dir, "${System.currentTimeMillis()}.txt").writeText(text)
        } catch (_: Exception) {}
    }

    private fun emitImage(bytes: ByteArray, ext: String) {
        try {
            val dir = File(filesDir, "clip_queue")
            dir.mkdirs()
            // Stage as .part then rename: the Dart watcher fires on create, and
            // an atomic rename guarantees it never reads a half-written image.
            val ts = System.currentTimeMillis()
            val part = File(dir, "$ts.$ext.part")
            part.writeBytes(bytes)
            // On rename failure the drain would never pick up the .part; delete
            // it so a retry (next onChange) isn't blocked by a stale orphan.
            if (!part.renameTo(File(dir, "$ts.$ext"))) part.delete()
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        shotObserver?.let {
            try {
                applicationContext.contentResolver.unregisterContentObserver(it)
            } catch (_: Exception) {}
        }
        shotObserver = null
        super.onDestroy()
    }
}
