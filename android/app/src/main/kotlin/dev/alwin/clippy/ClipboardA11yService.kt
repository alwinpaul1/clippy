package dev.alwin.clippy

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Context
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
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

    override fun onServiceConnected() {
        super.onServiceConnected()
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.addPrimaryClipChangedListener {
            pending?.let { main.removeCallbacks(it) }
            val r = Runnable { onClipChanged(cm) }
            pending = r
            main.postDelayed(r, 120)
        }
    }

    private var lastPoll = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // The bg clipboard listener is dead on One UI, so use accessibility
        // events as a "user might have copied" trigger to read the clipboard
        // via the focus-trick. Only text-selection / clicks (copies happen
        // around those) — NOT text-changed, which fires while typing and would
        // flicker constantly. Throttled so rapid events don't thrash.
        val t = event?.eventType ?: return
        if (t != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED &&
            t != AccessibilityEvent.TYPE_VIEW_CLICKED
        ) return
        val now = System.currentTimeMillis()
        if (now - lastPoll < 1200) return
        lastPoll = now
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
}
