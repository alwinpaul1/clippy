package dev.alwin.clippy

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.SystemClock
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The ONE native path that puts an incoming clip on the Android clipboard,
 * reachable from BOTH Flutter engines: the UI engine (MainActivity) and the
 * headless foreground-service engine (ClippyApp's task listener). Two reasons it
 * exists instead of Dart writing through super_clipboard:
 *
 *  1. Images. super_clipboard's DataProvider serves an EMPTY file to paste
 *     targets, so an image it wrote could not be pasted anywhere. The service
 *     engine used to have no native writer at all, so a Mac→phone image that
 *     arrived while Clippy's UI was gone landed as an unpasteable clip.
 *  2. Self-write detection. Our own write posts the same "Copied" toast a user
 *     copy does, and ClipboardA11yService used to answer it with a focus-grab
 *     read of the clip we had just written: a screen flash per incoming clip,
 *     plus an echo. Every write here stamps [lastWriteAt] so the service can
 *     tell its own write from the user's.
 */
object ClipWriter {
    const val CHANNEL = "clippy/clipwrite"

    // How long after our own write a copy trigger is treated as that write's
    // echo. The Samsung toast lands ~30 ms after the write and the service's
    // read ~150 ms after that; 1.5 s covers a slow device without swallowing a
    // real user copy made right after a clip arrived.
    private const val SELF_WRITE_WINDOW_MS = 1500L

    @Volatile
    private var lastWriteAt = 0L

    fun wroteRecently(): Boolean =
        lastWriteAt != 0L && SystemClock.uptimeMillis() - lastWriteAt < SELF_WRITE_WINDOW_MS

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "writeText" -> {
                    val text = call.argument<String>("text")
                    result.success(text != null && writeText(app, text))
                }
                "writeImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val ext = call.argument<String>("ext") ?: "png"
                    result.success(bytes != null && bytes.isNotEmpty() && writeImage(app, bytes, ext))
                }
                else -> result.notImplemented()
            }
        }
    }

    fun writeText(context: Context, text: String): Boolean = try {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        lastWriteAt = SystemClock.uptimeMillis()
        cm.setPrimaryClip(ClipData.newPlainText("clippy", text))
        true
    } catch (_: Exception) {
        false
    }

    // Image bytes go out through a FileProvider content URI, verbatim (never
    // re-encoded, see the image-clipboard notes). The file is per-write so a
    // paste of the previous clip that is still reading its URI is not handed
    // the new image's bytes halfway through. The last few are kept (clipboard
    // history UIs such as Samsung's may still point at them); older ones go.
    fun writeImage(context: Context, bytes: ByteArray, ext: String): Boolean = try {
        val dir = File(context.cacheDir, "clip_out").apply { mkdirs() }
        dir.listFiles()?.sortedByDescending { it.lastModified() }?.drop(3)?.forEach { it.delete() }
        val file = File(dir, "image_${System.currentTimeMillis()}.$ext")
        file.writeBytes(bytes)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        lastWriteAt = SystemClock.uptimeMillis()
        cm.setPrimaryClip(ClipData.newUri(context.contentResolver, "clippy", uri))
        true
    } catch (_: Exception) {
        false
    }
}
