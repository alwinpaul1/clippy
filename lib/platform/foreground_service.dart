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
import '../core/models/remote_clip.dart';
import '../core/state/prefs_state_store.dart';
import '../core/sync/sync_action.dart';
import '../core/sync/sync_engine.dart';
import 'clip_queue.dart';
import 'device_name.dart';
import 'image_clipboard.dart';
import 'secure_key_store.dart';

/// Entry point for the foreground-service isolate. The handler keeps a relay
/// connection and clip-queue watcher alive AT ALL TIMES (zero handover gap on
/// swipe-from-Recents); the UI isolate's heartbeat only decides who applies
/// incoming clips to the clipboard and who scans for screenshots.
@pragma('vm:entry-point')
void clippyServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_BackgroundSyncHandler());
}

class _BackgroundSyncHandler extends TaskHandler {
  // The service stays connected at ALL times (so there is zero handover gap
  // when the app is swiped from Recents) — this timeout only decides who
  // WRITES the clipboard / scans screenshots: while the UI pings, it owns
  // those; when pings stop, this isolate takes them over. Sized to tolerate
  // two dropped heartbeats (see uiPingInterval below) before flipping.
  static const _uiTimeout = Duration(
    seconds: ForegroundServiceManager.uiPingIntervalSeconds * 2 + 2,
  );

  // Samsung saves to DCIM/Screenshots; stock Android to Pictures/Screenshots.
  // With READ_MEDIA_IMAGES granted, media files are readable by direct path
  // (scoped storage passes reads through MediaProvider since Android 11).
  static const _screenshotDirs = [
    '/storage/emulated/0/DCIM/Screenshots',
    '/storage/emulated/0/Pictures/Screenshots',
  ];

  // Epoch, not now(): until a heartbeat proves the UI isolate is alive,
  // assume it's dead (boot autostart). Worst case both isolates briefly apply
  // the same incoming text — harmless; the reverse (neither applies) isn't.
  DateTime _lastUiPing = DateTime.fromMillisecondsSinceEpoch(0);
  // Screenshot-scan floor. _lastUiPing can't serve: at boot it's the epoch,
  // and without this floor the first scan would upload the phone's ENTIRE
  // screenshot history to the room.
  final DateTime _serviceStart = DateTime.now();
  WebSocketClipStore? _store;
  StreamSubscription? _sub;
  StreamSubscription? _queueWatch;
  StreamSubscription? _connWatch;
  RemoteClip? _skippedWhileUiAlive;
  SyncEngine? _engine;
  bool _starting = false;
  String _deviceName = '';
  final Set<String> _pushedShots = {};

  bool get _uiAlive => DateTime.now().difference(_lastUiPing) <= _uiTimeout;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Connect immediately and stay connected — a copy made right after the
    // app is swiped away must sync with no handover gap.
    unawaited(_ensureRunning());
  }

  @override
  void onReceiveData(Object data) {
    if (data == ForegroundServiceManager.uiAlivePing) {
      _lastUiPing = DateTime.now();
      // UI is alive and owns applying incoming clips, so drop any buffered
      // one — keeping it risks re-applying a stale/superseded clip on a later
      // swipe-away.
      _skippedWhileUiAlive = null;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_ensureRunning()); // reconnect safety net
    // Drain clips the background AccessibilityService captured (the queue
    // watcher fires instantly; this tick is the fallback).
    unawaited(_drainQueue());
    // While the relay is unreachable the queue only grows (drains are gated
    // on a confirmed link) — keep the disk bounded. This isolate's link being
    // down says nothing about the UI isolate's independent connection, so
    // the disconnected gate is only a cost optimization; enforceBound's
    // drain.lock heartbeat is what actually prevents racing an active drain
    // in either isolate.
    if (!(_store?.isConnected ?? false)) {
      unawaited(ClipQueue.enforceBound());
    }
    if (!_uiAlive) {
      // A clip that arrived while the last heartbeat was stale (UI already
      // dead but _uiTimeout not yet elapsed) was skipped, not lost — apply
      // it now that the UI is confirmed gone.
      final skipped = _skippedWhileUiAlive;
      _skippedWhileUiAlive = null;
      if (skipped != null) unawaited(_applyIncoming(skipped));
      // The activity's MediaStore observer died with the UI isolate, so pick
      // up new screenshots by scanning their folders.
      unawaited(_scanScreenshots());
    }
  }


  Future<void> _drainQueue() async {
    final engine = _engine;
    final store = _store;
    if (engine == null || store == null) return;
    // Draining consumes the on-disk queue file — the only copy that survives
    // a process kill. Leave it there until the relay link is confirmed; the
    // connected listener drains the instant we're back.
    if (!store.isConnected) return;
    final items = await ClipQueue.drain();
    for (var i = 0; i < items.length; i++) {
      // The link can die mid-drain (the files are already consumed) — put the
      // undelivered remainder back on disk so a process kill can't lose it.
      if (!store.isConnected) {
        await ClipQueue.requeueAll(items.sublist(i));
        return;
      }
      final item = items[i];
      final actions = item.isImage
          ? await engine.onLocalImage(
              base64Encode(item.imageBytes!),
              mime: item.mime ?? 'image/png',
            )
          : await engine.onLocalClip(
              ClipEvent(
                text: item.text!,
                byteSize: utf8.encode(item.text!).length,
              ),
            );
      for (final a in actions) {
        if (a is UploadClip) {
          await store.append(a.clip.copyWith(device: _deviceName));
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
      'gif': 'image/gif',
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
        // Only screenshots taken after the UI's last sign of life AND after
        // this service came up (pre-existing files are never ours to push),
        // settled for 2s+ so we never read a half-written file.
        final age = DateTime.now().difference(modified);
        if (modified.isBefore(_lastUiPing) ||
            modified.isBefore(_serviceStart) ||
            age < const Duration(seconds: 2)) {
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
      // Subscribe BEFORE any await below: the join reply can land during
      // those awaits, and a broadcast stream doesn't replay missed events —
      // the "drain the moment we're back" promise would silently degrade to
      // the 10s tick.
      _connWatch = store.connected.listen((up) {
        if (up) unawaited(_drainQueue());
      });
      if (kDebugMode) {
        debugPrint('[clippy-bg] receive loop started');
        unawaited(store.history.first.then(
          (h) => debugPrint('[clippy-bg] snapshot: ${h.length} clips'),
        ));
      }
      _sub = store.incoming.listen((clip) async {
        // While the UI isolate lives it applies incoming clips itself. But a
        // stale heartbeat can lie for up to _uiTimeout after a swipe-away, so
        // don't discard: buffer the newest skipped clip and apply it the
        // MOMENT the ownership window expires (not at the next 10s tick), so a
        // Mac->phone copy right after swiping lands with no tick latency.
        if (_uiAlive) {
          _skippedWhileUiAlive = clip;
          final remaining = _uiTimeout - DateTime.now().difference(_lastUiPing);
          Future.delayed(remaining + const Duration(milliseconds: 200), () {
            final pending = _skippedWhileUiAlive;
            if (pending == null || _uiAlive) return;
            _skippedWhileUiAlive = null;
            unawaited(_applyIncoming(pending));
          });
          return;
        }
        _skippedWhileUiAlive = null;
        await _applyIncoming(clip);
      });
      // Instant outgoing sync: text AND screenshots the AccessibilityService
      // captures land in filesDir/clip_queue, whose inotify watch is reliable
      // (app-private ext4, unlike external storage's FUSE). The 10s tick stays
      // as a safety net and the no-accessibility fallback.
      final queueEvents = await ClipQueue.watch();
      _queueWatch = queueEvents?.listen((_) => unawaited(_drainQueue()));
      // Catch-up: if the join reply landed during the awaits above, the
      // connected event already fired — drain now rather than at the tick.
      if (store.isConnected) unawaited(_drainQueue());
    } finally {
      _starting = false;
    }
  }

  Future<void> _applyIncoming(RemoteClip clip) async {
    final engine = _engine;
    if (engine == null) return;
    final actions = await engine.onRemoteSnapshot(clip);
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
      } catch (_) {
        // Background clipboard write failed — the clip stays in room
        // history and applies on the next app open.
      }
    }
  }

  void _stop() {
    _connWatch?.cancel();
    _connWatch = null;
    _queueWatch?.cancel();
    _queueWatch = null;
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

  /// Heartbeat cadence — coupled to the service's ownership timeout
  /// (_uiTimeout = 2 intervals + 2s), so tune them together, here.
  static const uiPingIntervalSeconds = 5;
  static const uiPingInterval = Duration(seconds: uiPingIntervalSeconds);

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
