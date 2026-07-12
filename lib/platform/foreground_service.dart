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
    // down says nothing about the UI isolate's independent connection, so the
    // disconnected gate is only a cost optimization. Two things actually keep
    // enforceBound from eating an active drain: the per-file age gate (a file
    // younger than a minute is never prunable, so a fresh capture or requeue
    // protects itself by its own mtime) and ClipQueue's drain heartbeat (a
    // drain live in EITHER isolate stands the pruner down, which matters
    // because pruning is oldest-first — exactly the batches a drain is working
    // through).
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


  bool _draining = false;

  Future<void> _drainQueue() async {
    final engine = _engine;
    final store = _store;
    if (engine == null || store == null) return;
    // Draining consumes the on-disk queue file — the only copy that survives
    // a process kill. Leave it there until the relay link is confirmed; the
    // connected listener drains the instant we're back.
    if (!store.isConnected) return;
    // The inotify watcher fires per file and the connected listener fires on
    // every reconnect, so drains can overlap — two passes would list, read and
    // upload the SAME file before either deletes it (duplicate clips, and the
    // older one lands last as the room's newest).
    if (_draining) return;
    _draining = true;
    var i = 0;
    var items = const <ClipQueueItem>[];
    try {
      // drain() returns a bounded BATCH (a long-dead service can leave an
      // enormous backlog), so keep going until the disk is dry.
      while (store.isConnected) {
        i = 0;
        items = await ClipQueue.drain();
        if (items.isEmpty) break;
        for (; i < items.length; i++) {
          // The link can die mid-drain (the files are already consumed) — the
          // finally below puts the undelivered remainder back on disk.
          if (!store.isConnected) return;
          final item = items[i];
          // Keep the heartbeat fresh through the uploads (see clip_controller).
          await ClipQueue.beat();
          try {
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
            ClipQueue.clearFailures(item.name);
          } catch (_) {
            // One bad item must not poison the batch — and requeueing it
            // unconditionally would spin (the requeue re-fires the watcher,
            // which drains it again, which throws again). Retry a couple of
            // times, then drop it.
            if (!ClipQueue.isPoison(item.name)) await ClipQueue.requeue(item);
          }
        }
      }
    } finally {
      // ANY early exit — a dead link, or a throw from the engine/store (an
      // encode failure, a closing socket) — leaves the remaining items holding
      // the only copy of clips whose disk files drain() already deleted.
      if (i < items.length) await ClipQueue.requeueAll(items.sublist(i));
      _draining = false;
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
        try {
          final bytes = await e.readAsBytes();
          if (bytes.isEmpty) continue; // still being written — retry next tick
          // Marked only once the read SUCCEEDED: marking up front meant a
          // transient failure (a MediaProvider hiccup, an OEM still
          // recompressing the file) blacklisted that screenshot for the life of
          // the service — it would never sync, and nothing would ever say so.
          _pushedShots.add(e.path);
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
  /// Host-test override for the platform gate (same hook style as
  /// [ClipQueue.debugDir]): every method below early-returns off Android, so
  /// without this the service state machine would be untestable.
  @visibleForTesting
  static bool? debugIsAndroid;

  /// Clear the static machine between tests. Without this, one test's in-flight
  /// poll or backoff counter silently disables the next one — a suite that
  /// lies is worse than no suite.
  @visibleForTesting
  static void resetForTests() {
    stopHealthWatch();
    _polling = false;
    _starting = false;
    _reviveFailures = 0;
    _reviveSkips = 0;
  }

  static bool get _isAndroid =>
      debugIsAndroid ?? (!kIsWeb && Platform.isAndroid);

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
        // ...and after an app update. Without this, every in-app update ended
        // background sync until the user happened to open Clippy again — the
        // process (and its service) dies with the package replace, and nothing
        // restarts it.
        autoRunOnMyPackageReplaced: true,
        // Survive swipe-from-recents: the plugin re-arms a restart alarm
        // instead of stopping (so the background receive loop keeps running).
        stopWithTask: false,
      ),
    );
  }

  /// Whether the background service is actually up. The relay dot in the UI
  /// only reflects the UI isolate's OWN connection, so a dead service still
  /// showed a green "Synced" — which is precisely why a six-hour outage went
  /// unnoticed for weeks. This is the honest signal.
  static final ValueNotifier<bool> backgroundSyncAlive = ValueNotifier(true);

  /// Bumped whenever the service's declared type changes. The plugin persists
  /// serviceTypes in its OWN prefs and replays them on the next boot/restart —
  /// so an install carrying a stale type would restart with a type the manifest
  /// no longer declares, and the system kills the service (the very failure
  /// this type change fixes). A version mismatch forces one stop+start, which
  /// is the only thing that rewrites those persisted options.
  static const _serviceTypesVersion = 2; // 1 = legacy dataSync, 2 = specialUse
  static const _typesVersionKey = 'fgs_service_types_version';

  /// Publish liveness, invalidating any health poll already in flight — its
  /// answer is older than this one and must not overwrite it.
  static void _publishAlive(bool alive) {
    _healthGen++;
    backgroundSyncAlive.value = alive;
  }

  /// Start the background service, migrating a stale service type if needed.
  ///
  /// NEVER throws: this is awaited inside ClipController.init() BEFORE the
  /// lifecycle observer and screenshot sync are wired up, so an escape here
  /// would take the rest of the Android integration down with it. Failures are
  /// reported through [backgroundSyncAlive], which the UI surfaces.
  ///
  /// The plugin does not throw either: start/stop return a ServiceRequestResult
  /// with the error folded inside, and they ALREADY wait (5s deadline) for the
  /// service state to actually flip. Those results must therefore be CHECKED —
  /// a stop that times out leaves the OLD service running, and asking
  /// `isRunningService` afterwards would answer "yes" about the very service we
  /// were trying to replace: we would record the migration as done and strand
  /// the phone on the stale type forever.
  /// [askBatteryExemption] opens a SYSTEM DIALOG when the app isn't exempt, so
  /// only the app-launch path passes it. A poll-driven revive must never fire
  /// it: on a phone whose OEM keeps refusing the service, every retry would
  /// throw the dialog back in the user's face, and dismissing it resumes the
  /// app, which polls, which retries, which opens it again — inescapable.
  static Future<void> start({bool askBatteryExemption = false}) async {
    if (!_isAndroid) return;
    if (_starting) return; // re-entrancy: init and a resume can race
    _starting = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stale =
          (prefs.getInt(_typesVersionKey) ?? 1) != _serviceTypesVersion;
      if (await FlutterForegroundTask.isRunningService) {
        if (!stale) {
          _publishAlive(true);
          return;
        }
        // Running under the old persisted type — stop it so the start below
        // rewrites the options with the current one.
        final stopped = await FlutterForegroundTask.stopService();
        if (stopped is! ServiceRequestSuccess) {
          // The old service is still up, on the stale type. Leave the version
          // unwritten so the next launch retries, and don't vouch for health
          // we don't have.
          _publishAlive(false);
          return;
        }
      }
      final started = await FlutterForegroundTask.startService(
        serviceId: 4242,
        // specialUse, NOT dataSync: Android 15+ stops a dataSync service after
        // 6 hours per 24h and then refuses to restart it — and bans it from
        // BOOT_COMPLETED starts outright — so background sync died for the rest
        // of the day AND after every reboot, and clips only moved when the app
        // was opened. Must stay in sync with android:foregroundServiceType in
        // the manifest (CI enforces it) AND with [_serviceTypesVersion] above.
        serviceTypes: const [ForegroundServiceTypes.specialUse],
        notificationTitle: 'Clippy',
        notificationText: 'Clipboard sync active',
        callback: clippyServiceCallback,
      );
      final ok = started is ServiceRequestSuccess;
      // Record the migration ONLY once the new service actually came up — a
      // failed start must be retried next launch, not remembered as done.
      if (ok) await prefs.setInt(_typesVersionKey, _serviceTypesVersion);
      _publishAlive(ok);
      if (askBatteryExemption) unawaited(_askBatteryExemption());
    } catch (_) {
      // Prefs/channel calls still throw — report, never break app init.
      _publishAlive(false);
    } finally {
      _starting = false;
    }
  }

  static bool _starting = false;

  /// Ask to be exempted from battery optimization — the exemption is what lifts
  /// the background-FGS-start restrictions, so the boot and package-replaced
  /// receivers can revive the service.
  ///
  /// NOT awaited by [start]: this opens a system dialog and the future only
  /// completes when the user answers it. Awaiting it inside start() stalls
  /// ClipController.init() — which has not yet registered the lifecycle
  /// observer or the health watch — for as long as that dialog is up, and if
  /// the user backgrounds Clippy from it, neither ever gets registered.
  ///
  /// (Deliberately NOT requesting notification permission, by contrast: Clippy
  /// posts no real notifications, and on Android 13+ an FGS whose app lacks the
  /// permission runs fine with its required notification simply never shown.)
  static Future<void> _askBatteryExemption() async {
    try {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {
      // The user can decline; sync still works while the app is alive.
    }
  }

  /// Re-check (and revive) the service. It can die with no signal to the user:
  /// an OEM battery manager sleeps it, a platform restriction refuses a
  /// restart, an update replaced the package. If it stays down,
  /// [backgroundSyncAlive] tells the UI to say so instead of showing a green
  /// light that only knows about the foreground connection.
  static Future<void> ensureRunning() async {
    if (!_isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        _publishAlive(true);
        return;
      }
    } catch (_) {
      _publishAlive(false);
      return;
    }
    await start(); // publishes the resulting state and never throws
  }

  @visibleForTesting
  static Duration healthPollInterval = const Duration(seconds: 20);
  static Timer? _healthTimer;
  // Bumped on every publish/cancel: a poll's answer is discarded if anything
  // newer landed while its platform call was in flight (they can resolve out
  // of order, and a stale `false` over a live service is the same lie again).
  static int _healthGen = 0;

  /// Watch the service's liveness WHILE the app is in the foreground. A kill
  /// can land at any moment (OEM battery manager, platform restriction), not
  /// just while we were away — and [ensureRunning]'s resume-time check would
  /// leave the header claiming "Synced" until the next lifecycle transition,
  /// which is the same lie this whole change exists to stop telling.
  ///
  /// Also REPAIRS: a death found here is revived on the spot (the user is
  /// looking at the app, so "reopen Clippy" is not an instruction they can
  /// follow). Retries back off exponentially — a system that is flatly refusing
  /// the service must not be fought once per poll forever — and the revive
  /// never asks for the battery exemption, whose system dialog would otherwise
  /// reappear on every attempt.
  static void startHealthWatch() {
    if (!_isAndroid || _healthTimer != null) return;
    // Check immediately: re-arming (every focus regain — a pulled-down
    // notification shade counts) restarts the interval from zero, so a
    // frequently-refocused app would otherwise never reach its first poll.
    unawaited(_pollHealth());
    _healthTimer = Timer.periodic(healthPollInterval, (_) => _pollHealth());
  }

  static void stopHealthWatch() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _healthGen++; // any in-flight poll's answer is now void
  }

  static bool _polling = false;

  static Future<void> _pollHealth() async {
    if (_polling) return; // a slow channel call must not stack up ticks
    _polling = true;
    final gen = _healthGen;
    try {
      final alive = await FlutterForegroundTask.isRunningService;
      // Anything published while this call was in flight (a start(), a stop,
      // a cancelled watch) is NEWER than this reading — never overwrite it.
      if (gen != _healthGen) return;
      backgroundSyncAlive.value = alive;
      if (alive) {
        _reviveFailures = 0;
        return;
      }
      // Don't just report the death — repair it. The user is LOOKING at the
      // app, so "open Clippy to sync" is not an instruction they can follow,
      // and without it the service stays dead for the whole foreground session
      // (resume-time ensureRunning never fires while the app never leaves
      // `resumed`). Backed off: when the system is flatly refusing to start the
      // service, retrying every 20s forever just burns battery and log.
      if (_reviveSkips > 0) {
        _reviveSkips--;
        return;
      }
      // _polling stays TRUE across this await: start() never polls, and
      // releasing the guard here would let the next tick start a second poll
      // whose finally then clears the flag out from under this one — the very
      // stacking the guard exists to prevent.
      await start();
      if (backgroundSyncAlive.value) {
        _reviveFailures = 0;
        _reviveSkips = 0;
      } else {
        _reviveFailures++;
        // 1, 2, 4, 8… polls between attempts, capped (~10 min at a 20s poll).
        _reviveSkips = (1 << _reviveFailures.clamp(0, 5)).clamp(1, 30);
      }
    } catch (_) {
      if (gen == _healthGen) backgroundSyncAlive.value = false;
    } finally {
      _polling = false;
    }
  }

  static int _reviveFailures = 0;
  static int _reviveSkips = 0;

  static Future<void> stop() async {
    if (!_isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
