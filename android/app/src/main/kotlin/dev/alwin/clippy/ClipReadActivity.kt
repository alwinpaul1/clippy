package dev.alwin.clippy

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * An invisible activity that takes focus for the moment a clipboard read needs.
 * Two callers:
 *
 *  - ClipboardA11yService, when its 1px overlay never gets focus. Screens that
 *    set HIDE_NON_SYSTEM_OVERLAY_WINDOWS (Settings, banking apps, installers,
 *    password managers) hide every TYPE_APPLICATION_OVERLAY window, so the
 *    overlay is never shown and the read is denied. MEASURED on an S23 (One UI,
 *    SDK 36) on 2026-10-18: every copy made in Settings timed out that way, the
 *    Settings window carrying pfl=0x10088840 (0x80000 is that flag). That flag
 *    hides overlays only; it does not stop an activity from opening above it.
 *  - SendClipTileService, the quick-settings "Send clipboard" tile ([EXTRA_MANUAL]).
 *
 * It costs more than the overlay (it closes the keyboard), which is why the
 * overlay stays the first try and this is the fallback.
 */
class ClipReadActivity : Activity() {
    companion object {
        const val EXTRA_MANUAL = "manual"
        private const val TIMEOUT_MS = 2000L
    }

    private val main = Handler(Looper.getMainLooper())
    private var started = false
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        main.postDelayed({ finishRead(gotFocus = false) }, TIMEOUT_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || started || done) return
        started = true
        val svc = ClipboardA11yService.instance
        if (svc == null) {
            finishRead(gotFocus = true)
            return
        }
        // Stay focused until the read completes: the cross-app URI grant for a
        // copied image only applies while we hold focus.
        val queued = svc.readWhileFocused(intent.getBooleanExtra(EXTRA_MANUAL, false)) {
            finishRead(gotFocus = true)
        }
        if (!queued) finishRead(gotFocus = true)
    }

    private fun finishRead(gotFocus: Boolean) {
        if (done) return
        done = true
        main.removeCallbacksAndMessages(null)
        ClipboardA11yService.instance?.onReadActivityDone(gotFocus)
        finish()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        // Destroyed before it ever finished (system reclaimed it, screen off):
        // still release the service's busy state.
        if (!done) {
            done = true
            ClipboardA11yService.instance?.onReadActivityDone(started)
        }
        super.onDestroy()
    }
}
