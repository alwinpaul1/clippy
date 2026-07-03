import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point for the foreground-service isolate. The sync (WebSocket) lives in
/// the main isolate; this handler just needs to exist so the service can run and
/// keep the process alive while Clippy is backgrounded.
@pragma('vm:entry-point')
void clippyServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Runs an Android foreground service so Clippy keeps syncing when it isn't the
/// active app (Android otherwise suspends a backgrounded app's network).
/// No-op on non-Android platforms — desktop apps stay alive anyway.
class ForegroundServiceManager {
  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  static void init() {
    if (!_isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'clippy_sync',
        channelName: 'Clipboard sync',
        channelDescription:
            'Keeps your clipboard syncing across devices in the background.',
        onlyAlertOnce: true,
        // Keep the required foreground-service notification as unobtrusive as
        // Android allows: no status-bar icon, collapsed below the fold.
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        autoRunOnBoot: false,
      ),
    );
  }

  static Future<void> start() async {
    if (!_isAndroid) return;

    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 4242,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Clippy',
      notificationText: 'Clipboard sync active',
      callback: clippyServiceCallback,
    );
  }

  static Future<void> stop() async {
    if (!_isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
