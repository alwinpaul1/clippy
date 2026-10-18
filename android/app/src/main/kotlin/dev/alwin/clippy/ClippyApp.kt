package dev.alwin.clippy

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine

/**
 * Gives the headless foreground-service engine the native clipboard writer.
 * flutter_foreground_task builds a fresh FlutterEngine for every task start and
 * only registers pub plugins on it, so a channel set up in MainActivity never
 * exists there. Registered here, at process start, so a service the system
 * restarts on its own (no activity ever created) still gets it.
 */
class ClippyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(
            object : FlutterForegroundTaskLifecycleListener {
                override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                    flutterEngine ?: return
                    ClipWriter.register(this@ClippyApp, flutterEngine.dartExecutor.binaryMessenger)
                }

                override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}
                override fun onTaskRepeatEvent() {}
                override fun onTaskDestroy() {}
                override fun onEngineWillDestroy() {}
            },
        )
    }
}
