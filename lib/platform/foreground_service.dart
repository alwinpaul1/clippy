import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../app/relay_config.dart';
import '../core/backend/websocket_clip_store.dart';
import '../core/models/clip_event.dart';
import '../core/state/prefs_state_store.dart';
import '../core/sync/sync_action.dart';
import '../core/sync/sync_engine.dart';
import 'clip_queue.dart';
import 'device_name.dart';
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

  // Samsung saves to DCIM/Screenshots; stock Android to Pictures/Screenshots.
  // With READ_MEDIA_IMAGES granted, media files are readable by direct path
  // (scoped storage passes reads through MediaProvider since Android 11).
  static const _screenshotDirs = [
    '/storage/emulated/0/DCIM/Screenshots',
    '/storage/emulated/0/Pictures/Screenshots',
  ];

  DateTime _lastUiPing = DateTime.now();
  WebSocketClipStore? _store;
  StreamSubscription? _sub;
  SyncEngine? _engine;
  bool _starting = false;
  String _deviceName = '';
  final Set<String> _pushedShots = {};

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
      // The activity's MediaStore observer died with the UI isolate, so the
      // takeover also picks up new screenshots by scanning their folders.
      unawaited(_scanScreenshots());
      // Texts the Clippy keyboard captured while everything Dart was dead.
      unawaited(_drainImeQueue());
    } else {
      _stop();
    }
  }

  Future<void> _drainImeQueue() async {
    final engine = _engine;
    final store = _store;
    if (engine == null || store == null) return;
    for (final text in await ClipQueue.drain()) {
      final actions = await engine.onLocalClip(
        ClipEvent(text: text, byteSize: utf8.encode(text).length),
      );
      for (final a in actions) {
        if (a is UploadClip) {
          await store.append(a.clip.copyWith(device: _deviceName));
          if (kDebugMode) {
            debugPrint('[clippy-bg] pushed keyboard-captured clip');
          }
        }
      }
    }
  }

  Future<void> _scanScreenshots() async {
    final store = _store;
    final engine = _engine;
    if (store == null || engine == null) return;
    const mimes = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'webp': 'image/webp',
    };
    for (final dirPath in _screenshotDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync();
      } catch (_) {
        continue; // permission edge — the app-open path still covers it
      }
      for (final e in entries) {
        if (e is! File) continue;
        final mime = mimes[e.path.split('.').last.toLowerCase()];
        if (mime == null || _pushedShots.contains(e.path)) continue;
        DateTime modified;
        try {
          modified = e.lastModifiedSync();
        } catch (_) {
          continue;
        }
        // Only screenshots taken after the UI's last sign of life (older ones
        // were the activity observer's job), and settled for 2s+ so we never
        // read a half-written file.
        final age = DateTime.now().difference(modified);
        if (modified.isBefore(_lastUiPing) || age < const Duration(seconds: 2)) {
          continue;
        }
        _pushedShots.add(e.path);
        try {
          final bytes = await e.readAsBytes();
          if (bytes.isEmpty) continue;
          final (out, outMime) = ImageClipboard.prepareForRelay(bytes, mime: mime);
          final actions = await engine.onLocalImage(base64Encode(out), mime: outMime);
          for (final a in actions) {
            if (a is UploadClip) {
              await store.append(a.clip.copyWith(device: _deviceName));
              if (kDebugMode) {
                debugPrint('[clippy-bg] pushed screenshot '
                    '${e.path.split('/').last} (${bytes.length}b)');
              }
            }
          }
        } catch (_) {
          // Unreadable — leave it to the app-open capture.
        }
      }
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
      _deviceName = await resolveDeviceName();
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
        // LOW, not MIN: Google discourages IMPORTANCE_MIN for a foreground
        // service — it can backfire into a system-generated "battery usage"
        // nag. LOW keeps it quiet (no sound/badge) and, since we never request
        // POST_NOTIFICATIONS, it stays hidden on Android 13+ regardless.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Drives the heartbeat check in _BackgroundSyncHandler.
        eventAction: ForegroundTaskEventAction.repeat(10000),
        allowWakeLock: true,
        allowWifiLock: true,
        // Apple-ecosystem feel: sync comes back on its own after a reboot
        // (the service isolate runs the receive loop until the app is opened).
        autoRunOnBoot: true,
        // Survive swipe-from-recents: the plugin re-arms a restart alarm
        // instead of stopping (so the background receive loop keeps running).
        stopWithTask: false,
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
