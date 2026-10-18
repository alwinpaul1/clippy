package dev.alwin.clippy

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick-settings "Send clipboard" tile: the fallback that always works. One tap
 * reads whatever is on the clipboard (text or image) and syncs it, for the
 * copies automatic capture could not see. With background sync on it uses the
 * invisible read activity; without it, it opens Clippy, whose app-open read
 * picks the clip up.
 */
class SendClipTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.let {
            it.state = Tile.STATE_INACTIVE
            it.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val intent = if (ClipboardA11yService.instance != null) {
            Intent(this, ClipReadActivity::class.java)
                .putExtra(ClipReadActivity.EXTRA_MANUAL, true)
        } else {
            Intent(this, MainActivity::class.java)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        collapseAndStart(intent)
    }

    // Android 14 removed the Intent overload (it throws there); the
    // PendingIntent overload only exists from 14.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun collapseAndStart(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this, 0, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
