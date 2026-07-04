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

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // The bg clipboard listener is dead on One UI, so use accessibility
        // events as the "user just copied" trigger to read via the focus-trick.
        // Two signals (verified on-device):
        //  - Tapping "Copy" in Chrome's toolbar fires NO click; it COLLAPSES
        //    the text selection -> TEXT_SELECTION_CHANGED with from == to.
        //    That collapse is our reliable copy signal.
        //  - Some apps' Copy is a real TYPE_VIEW_CLICKED. Keep that too.
        // We must NOT read on a RANGED selection (from != to): that fires
        // continuously while you drag the selection handles, and each read
        // steals focus for a frame = visible flicker, for nothing (selecting
        // never changes the clipboard). Typing (IME / EditText events) is
        // likewise skipped.
        val t = event?.eventType ?: return
        val isSel = t == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED
        val isClick = t == AccessibilityEvent.TYPE_VIEW_CLICKED
        if (!isSel && !isClick) return
        val pkg = event.packageName?.toString().orEmpty().lowercase()
        val cls = event.className?.toString().orEmpty()
        val fromIme = pkg.contains("inputmethod") || pkg.contains("keyboard") ||
            pkg.contains("honeyboard") || pkg.contains("gboard") ||
            pkg.contains("swiftkey")
        if (fromIme || cls.contains("EditText")) return
        // Ranged selection = active drag -> skip (no flicker). Collapsed
        // selection (from == to) = copy/deselect -> read.
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
        readClip(cm)?.let { emit(it); return }
        focusTrickRead(cm)
    }

    override fun onInterrupt() {}

    private fun onClipChanged(cm: ClipboardManager) {
        // 1) Direct read — does the AS context have clipboard access in bg?
        val direct = readClip(cm)
        if (direct != null) {
            emit(direct)
            return
        }
        // 2) Fallback: focus-trick overlay (needs SYSTEM_ALERT_WINDOW).
        focusTrickRead(cm)
    }

    private fun readClip(cm: ClipboardManager): String? = try {
        cm.primaryClip?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)?.coerceToText(this)?.toString()?.takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        null
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
            readClip(cm)?.let { emit(it) }
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
            part.renameTo(File(dir, "$ts.$ext"))
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
