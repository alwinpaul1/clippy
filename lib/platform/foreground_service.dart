import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../app/relay_config.dart';
import '../core/backend/websocket_clip_store.dart';
import '../core/state/prefs_state_store.dart';
import '../core/sync/sync_action.dart';
import '../core/sync/sync_engine.dart';
import 'image_clipboard.dart';
import 'secure_key_store.dart';

/// Entry point for the foreground-service isolate. While the app's UI isolate
/// is alive it heartbeats us and this handler idles; when the heartbeats stop
/// (app swiped from Recents), the handler runs the receive loop itself so
/// incoming clips keep landing on the clipboard.
@pragma('vm:entry-point')
void clippyServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_BackgroundSyncHandler());
}

class _BackgroundSyncHandler extends TaskHandler {
  // Comfortably above the UI's 15s ping interval, so a couple of delayed
  // pings don't cause a spurious takeover.
  static const _uiTimeout = Duration(seconds: 40);

  DateTime _lastUiPing = DateTime.now();
  WebSocketClipStore? _store;
  StreamSubscription? _sub;
  SyncEngine? _engine;
  bool _starting = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onReceiveData(Object data) {
    if (data == ForegroundServiceManager.uiAlivePing) {
      _lastUiPing = DateTime.now();
      _stop(); // the UI isolate owns sync while it lives
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (DateTime.now().difference(_lastUiPing) > _uiTimeout) {
      unawaited(_ensureRunning());
    } else {
      _stop();
    }
  }

  Future<void> _ensureRunning() async {
    if (_store != null || _starting) return;
    _starting = true;
    try {
      final pairing = await const SecureKeyStore().load();
      if (pairing == null) return; // not paired yet — nothing to sync
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // long-lived isolate: skip stale caches
      final roomToken = await pairing.roomToken();
      _engine = SyncEngine(
        crypto: await pairing.cryptoBox(),
        state: await PrefsStateStore.create(),
        selfDeviceId: prefs.getString('clippy.deviceId') ?? 'background',
        clock: DateTime.now,
      );
      final store = WebSocketClipStore.connect(Uri.parse(relayUrl), roomToken);
      _store = store;
      if (kDebugMode) {
        debugPrint('[clippy-bg] takeover: receive loop started');
        unawaited(store.history.first.then(
          (h) => debugPrint('[clippy-bg] snapshot: ${h.length} clips'),
        ));
      }
      _sub = store.incoming.listen((clip) async {
        final actions = await _engine!.onRemoteSnapshot(clip);
        if (kDebugMode) {
          debugPrint('[clippy-bg] incoming ${clip.kind} '
              'age=${DateTime.now().difference(clip.timestamp).inSeconds}s '
              '-> ${actions.map((a) => a.runtimeType).toList()}');
        }
        for (final a in actions) {
          if (a is! ApplyToClipboard) continue;
          try {
            if (clip.kind == 'image') {
              await ImageClipboard.write(base64Decode(a.text));
            } else {
              // NOT Clipboard.setData: SystemChannels.platform needs an
              // Activity-backed engine, which this headless service isolate
              // lacks. super_clipboard is a real plugin (registered in the
              // service engine) and writes fine from here.
              final cb = SystemClipboard.instance;
              if (cb == null) continue;
              final item = DataWriterItem()..add(Formats.plainText(a.text));
              await cb.write([item]);
            }
            if (kDebugMode) {
              debugPrint('[clippy-bg] applied ${clip.kind} to clipboard');
            }
          } catch (_) {
            // Background clipboard write failed — the clip stays in room
            // history and applies on the next app open.
          }
        }
      });
    } finally {
      _starting = false;
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _store?.close();
    _store = null;
    _engine = null;
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async => _stop();
}

/// Runs an Android foreground service so Clippy keeps syncing when it isn't the
/// active app (Android otherwise suspends a backgrounded app's network).
/// No-op on non-Android platforms — desktop apps stay alive anyway.
class ForegroundServiceManager {
  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Heartbeat payload the UI isolate sends while it's alive.
  static const uiAlivePing = 'clippy.ui-alive';

  /// Tell the service isolate the UI isolate is alive (it idles while so).
  static void pingAlive() {
    if (!_isAndroid) return;
    try {
      FlutterForegroundTask.sendDataToTask(uiAlivePing);
    } catch (_) {
      // Service not up (yet) — the next ping catches it.
    }
  }

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
        // Drives the heartbeat check in _BackgroundSyncHandler.
        eventAction: ForegroundTaskEventAction.repeat(10000),
        allowWakeLock: true,
        allowWifiLock: true,
        autoRunOnBoot: false,
      ),
    );
  }

  static Future<void> start() async {
    if (!_isAndroid) return;

    // Deliberately NOT requesting notification permission: Clippy posts no
    // real notifications, and on Android 13+ a foreground service whose app
    // lacks the permission runs fine with its (required) notification simply
    // never displayed. That keeps background sync alive with no visible
    // "sync active" notification.
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
