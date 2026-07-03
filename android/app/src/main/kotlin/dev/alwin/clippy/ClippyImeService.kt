package dev.alwin.clippy

import android.content.ClipboardManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File

/**
 * The Clippy keyboard — the "bulletproof sync" path.
 *
 * Android's clipboard restriction (10+) exempts exactly one kind of app: the
 * user's DEFAULT input method. While Clippy is the default keyboard, the whole
 * app UID may read the clipboard from the background — so the listener here
 * fires on every copy in ANY app and syncs it instantly, even with Clippy
 * swiped away from Recents.
 *
 * Delivery: if the Flutter UI engine is alive, the text goes straight through
 * the share channel (instant). Otherwise it's queued as a file that the
 * foreground service's Dart isolate drains on its next tick (≤10s).
 */
class ClippyImeService : InputMethodService() {
    private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var shifted = false
    private var symbols = false
    private var keyboardRoot: LinearLayout? = null

    // Warm dark palette matching the app.
    private val bgColor = Color.parseColor("#141310")
    private val keyColor = Color.parseColor("#2A2721")
    private val keyAltColor = Color.parseColor("#3A362E")
    private val inkColor = Color.parseColor("#F4F1EA")
    private val accentColor = Color.parseColor("#7FB0A0")

    override fun onCreate() {
        super.onCreate()
        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        val listener = ClipboardManager.OnPrimaryClipChangedListener { onClipChanged(cm) }
        cm.addPrimaryClipChangedListener(listener)
        clipListener = listener
    }

    override fun onDestroy() {
        clipListener?.let {
            (getSystemService(CLIPBOARD_SERVICE) as ClipboardManager)
                .removePrimaryClipChangedListener(it)
        }
        clipListener = null
        super.onDestroy()
    }

    // --- instant clipboard capture (the whole point) ---

    private fun onClipChanged(cm: ClipboardManager) {
        try {
            val clip = cm.primaryClip ?: return
            if (clip.itemCount == 0) return
            val text = clip.getItemAt(0).coerceToText(this)?.toString() ?: return
            if (text.isBlank()) return
            android.util.Log.d("ClippyIme", "clip captured (${text.length} chars)")
            deliver(text)
        } catch (_: Exception) {
            // Not readable (shouldn't happen while we're the default IME).
        }
    }

    private fun deliver(text: String) {
        // Instant path: UI engine alive -> same pipeline as "Send to Clippy".
        val channel = MainActivity.activeShareChannel
        if (channel != null) {
            Handler(Looper.getMainLooper()).post {
                try {
                    channel.invokeMethod("onShared", text)
                } catch (_: Exception) {
                    queue(text)
                }
            }
            return
        }
        // Backstop: app swiped away -> queue for the foreground service's
        // Dart isolate (drained on its 10s tick; engine dedup handles echoes).
        queue(text)
    }

    private fun queue(text: String) {
        try {
            val dir = File(filesDir, "clip_queue")
            dir.mkdirs()
            File(dir, "${System.currentTimeMillis()}.txt").writeText(text)
        } catch (_: Exception) {
        }
    }

    // --- a small, honest QWERTY keyboard ---

    override fun onCreateInputView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(bgColor)
            setPadding(dp(4), dp(6), dp(4), dp(8))
        }
        keyboardRoot = root
        rebuild()
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        shifted = false
        symbols = false
        rebuild()
    }

    private fun rebuild() {
        val root = keyboardRoot ?: return
        root.removeAllViews()
        val rows = if (symbols) {
            listOf(
                "1 2 3 4 5 6 7 8 9 0".split(" "),
                "@ # $ % & - + ( ) /".split(" "),
                listOf("ABC", "*", "\"", "'", ":", ";", "!", "?", "DEL"),
                listOf("clip", ",", "SPACE", ".", "GO"),
            )
        } else {
            listOf(
                "q w e r t y u i o p".split(" "),
                "a s d f g h j k l".split(" "),
                listOf("SHIFT", "z", "x", "c", "v", "b", "n", "m", "DEL"),
                listOf("?123", ",", "SPACE", ".", "GO"),
            )
        }
        for (row in rows) {
            val line = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, dp(52),
                ).apply { setMargins(0, dp(3), 0, dp(3)) }
            }
            for (key in row) line.addView(makeKey(key))
            root.addView(line)
        }
    }

    private fun makeKey(key: String): TextView {
        val special = key in setOf("SHIFT", "DEL", "?123", "ABC", "SPACE", "GO", "clip")
        val weight = when (key) {
            "SPACE" -> 4.4f
            "SHIFT", "DEL", "?123", "ABC", "GO", "clip" -> 1.5f
            else -> 1f
        }
        val label = when (key) {
            "SHIFT" -> if (shifted) "⇧" else "⇧"
            "DEL" -> "⌫"
            "SPACE" -> ""
            "GO" -> "↵"
            "clip" -> "📎"
            else -> if (shifted && !symbols) key.uppercase() else key
        }
        return TextView(this).apply {
            text = label
            gravity = Gravity.CENTER
            setTextColor(if (key == "GO") bgColor else inkColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, if (special) 16f else 19f)
            typeface = Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                cornerRadius = dp(9).toFloat()
                setColor(
                    when {
                        key == "GO" -> accentColor
                        key == "SHIFT" && shifted -> keyAltColor
                        special -> keyAltColor
                        else -> keyColor
                    },
                )
            }
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, weight)
                .apply { setMargins(dp(2), 0, dp(2), 0) }
            setOnClickListener {
                it.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                onKey(key)
            }
            if (key == "SPACE") {
                // Long-press space -> keyboard picker (way back to Gboard etc.).
                setOnLongClickListener {
                    (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                        .showInputMethodPicker()
                    true
                }
            }
        }
    }

    private fun onKey(key: String) {
        val ic = currentInputConnection ?: return
        when (key) {
            "SHIFT" -> { shifted = !shifted; rebuild() }
            "?123" -> { symbols = true; rebuild() }
            "ABC" -> { symbols = false; rebuild() }
            "DEL" -> ic.deleteSurroundingText(1, 0)
            "SPACE" -> ic.commitText(" ", 1)
            "GO" -> {
                if (!sendDefaultEditorAction(true)) ic.commitText("\n", 1)
            }
            "clip" -> {
                // Paste the current clipboard (i.e. the latest synced clip —
                // incoming clips are auto-applied to the clipboard).
                val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                val t = cm.primaryClip?.takeIf { it.itemCount > 0 }
                    ?.getItemAt(0)?.coerceToText(this)?.toString()
                if (!t.isNullOrEmpty()) ic.commitText(t, 1)
            }
            else -> {
                val out = if (shifted && !symbols) key.uppercase() else key
                ic.commitText(out, 1)
                if (shifted) { shifted = false; rebuild() }
            }
        }
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()
}
