import 'dart:async';
import 'dart:convert';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/remote_clip.dart';
import '../platform/clip_queue.dart';

import '../core/backend/websocket_clip_store.dart';
import '../core/history/history_item.dart';
import '../core/history/history_store.dart';
import '../core/models/clip_event.dart';
import '../core/pairing/pairing_key.dart';
import '../core/state/prefs_state_store.dart';
import '../core/sync/sync_action.dart';
import '../core/sync/sync_engine.dart';
import '../platform/device_name.dart';
import '../platform/flutter_clipboard_writer.dart';
import '../platform/foreground_service.dart';
import '../platform/image_clipboard.dart';
import '../platform/mac_screenshot_watcher.dart';
import '../platform/share_channel.dart';
import 'relay_config.dart';

/// Orchestrates the whole client: pairing key → content keys + room token →
/// relay connection → SyncEngine (apply-latest) + HistoryStore (browsable list).
/// On desktop it auto-captures system-clipboard changes; everywhere it applies
/// incoming clips and exposes the synced history.
class ClipController extends ChangeNotifier
    with ClipboardListener, WidgetsBindingObserver {
  final String deviceId;
  ClipController({required this.deviceId});

  static const _writer = FlutterClipboardWriter();

  SyncEngine? _engine;
  HistoryStore? _historyStore;
  WebSocketClipStore? _store;
  StreamSubscription? _historySub;
  StreamSubscription? _incomingSub;
  StreamSubscription? _connectedSub;
  bool _watching = false;
  bool _disposed = false;
  MacScreenshotWatcher? _macShots;
  Timer? _uiPing;
  String _deviceName = '';
  // After we write an incoming image to the clipboard, ignore the watcher's
  // resulting change for a moment (PNG round-trips aren't byte-identical, so a
  // content fingerprint can't catch this echo).
  DateTime? _suppressImageUntil;
  // The clipboard content we already synced, in either direction. The resume
  // hook re-reads the clipboard every time Clippy returns to the foreground,
  // and the engine's echo window (~2s) can't cover a minutes-later re-read —
  // without this, every app-open would re-upload the current clip. Text is
  // matched exactly; an image is matched by a format-agnostic fingerprint of
  // its picture — the platform hands our own write back re-encoded (a received
  // JPEG re-reads as PNG), so a raw-byte / content-hash compare misses the echo.
  String? _handledText;
  String? _handledImageFp;
  bool _incomingImagePending = false;

  List<HistoryItem> history = const [];
  bool ready = false;
  bool connected = false;
  // Android screenshot auto-sync access: 'granted' | 'partial' | 'denied' |
  // 'unavailable'. 'partial' means the user picked "Select photos" and new
  // screenshots won't sync until they grant full access.
  String screenshotAccess = 'granted';

  bool get isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  Future<void> start(PairingKey pairing) async {
    _deviceName = await resolveDeviceName();
    final crypto = await pairing.cryptoBox();
    final roomToken = await pairing.roomToken();
    final state = await PrefsStateStore.create();

    _engine = SyncEngine(
      crypto: crypto,
      state: state,
      selfDeviceId: deviceId,
      clock: DateTime.now,
    );
    _historyStore = HistoryStore(crypto: crypto, writer: _writer);

    // Instant open: render the locally cached (still-encrypted) clips before
    // the relay round-trip completes; the live snapshot replaces them. The
    // cache key is room-scoped so a re-pair can never surface another room's
    // clips.
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'clippy.clips.${roomToken.hashCode.toRadixString(16)}';
    final cached = prefs.getString(cacheKey);
    if (cached != null) {
      try {
        final clips = (jsonDecode(cached) as List).map((m) {
          final map = (m as Map).cast<String, dynamic>();
          return RemoteClip.fromMap(
            map,
            timestamp: DateTime.parse(map['ts'] as String).toLocal(),
          );
        }).toList();
        history = await _historyStore!.project(clips);
        notifyListeners();
      } catch (_) {
        // Corrupt cache — the live snapshot will overwrite it shortly.
      }
    }

    _store = WebSocketClipStore.connect(Uri.parse(relayUrl), roomToken);

    _historySub = _store!.history.listen((clips) async {
      history = await _historyStore!.project(clips);
      notifyListeners();
      // Refresh the instant-open cache: encrypted clips only, and skip large
      // image payloads so prefs stays small (images stream in on connect).
      final small = clips
          .where((c) => c.ciphertext.length <= 64000)
          .map((c) => {
                'ciphertext': c.ciphertext,
                'iv': c.iv,
                'hash': c.hash,
                'source': c.source,
                'device': c.device,
                'kind': c.kind,
                'mime': c.mime,
                'ts': c.timestamp.toUtc().toIso8601String(),
              })
          .toList();
      await prefs.setString(cacheKey, jsonEncode(small));
      // If the last-applied clip was deleted (here or on another device),
      // clear its persisted hash so re-copying that content syncs again
      // instead of being deduped by the engine's Rule 2b.
      final last = await state.readLastAppliedHash();
      if (last != null &&
          last.isNotEmpty &&
          history.every((i) => i.hash != last)) {
        await state.writeLastAppliedHash('');
      }
    });
    _incomingSub = _store!.incoming.listen((clip) async {
      final actions = await _engine!.onRemoteSnapshot(clip);
      for (final a in actions) {
        // Auto-place the latest clip on the system clipboard so it can be
        // pasted on this device without opening Clippy. (On Android this pops
        // the system "Copied" toast — unavoidable.) OfferRestore is not
        // auto-applied.
        if (a is! ApplyToClipboard) continue;
        if (clip.kind == 'image') {
          try {
            final jpeg = base64Decode(a.text);
            _suppressImageUntil =
                DateTime.now().add(const Duration(seconds: 3));
            _incomingImagePending = true;
            // Register the picture up front so the watcher's re-encoded
            // read-back is recognised as our own echo however much later it
            // fires (macOS App Nap can delay it well past the time window).
            _handledImageFp = await ImageClipboard.fingerprint(jpeg);
            await ImageClipboard.write(jpeg);
          } catch (_) {
            // Corrupt payload — skip.
          }
        } else {
          _handledText = a.text; // suppress the resume/watcher re-read echo
          await _writer.setText(a.text);
        }
      }
    });
    _connectedSub = _store!.connected.listen((up) {
      connected = up;
      notifyListeners();
    });
    connected = _store!.isConnected; // catch the initial state

    if (isDesktop) {
      clipboardWatcher.addListener(this);
      await clipboardWatcher.start();
      _watching = true;
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        // File-saved screenshots (⇧⌘3/4 → Desktop) bypass the clipboard;
        // watch the screenshot folder and sync those too.
        _macShots = MacScreenshotWatcher(
          (bytes, mime) => _pushLocalImage(bytes, mime: mime),
        );
        unawaited(_macShots!.start());
      }
    } else {
      // Keep receiving in the background so copies from other devices land on
      // the phone's clipboard without opening Clippy. Android requires a
      // foreground-service notification for this (kept at MIN importance).
      await ForegroundServiceManager.start();
      // Android 10+ blocks clipboard reads while backgrounded (for every app,
      // service or not), so capture outgoing copies the moment Clippy returns
      // to the foreground instead.
      WidgetsBinding.instance.addObserver(this);
      // Screenshots never touch the Android clipboard — watch MediaStore and
      // sync new ones directly. Not awaited: the first call pops the
      // photo-access dialog, and startup shouldn't block on the answer.
      unawaited(_startScreenshotSync());
      // Sync anything the background AccessibilityService captured.
      unawaited(_drainQueue());
      // Heartbeat the service isolate: it stays connected at all times, but
      // only writes the clipboard / scans screenshots when our pings stop
      // (swipe-away) — the heartbeat decides ownership, not connection.
      ForegroundServiceManager.pingAlive();
      _uiPing = Timer.periodic(
        ForegroundServiceManager.uiPingInterval,
        (_) => ForegroundServiceManager.pingAlive(),
      );
      // Queue items the AccessibilityService captures are drained instantly
      // by the always-connected service isolate; the start/resume drains in
      // this isolate are only a safety net for when the service isn't up.
    }

    ready = true;
    notifyListeners();

    // "Send to Clippy" (Android share sheet + text-selection popup) → sync it.
    // One tap, no special permissions; on desktop the channel is absent.
    ShareChannel.listen(
      onText: _pushLocal,
      onImage: (bytes, mime) => _pushLocalImage(bytes, mime: mime),
    );
    await ShareChannel.initial(
      onText: _pushLocal,
      onImage: (bytes, mime) => _pushLocalImage(bytes, mime: mime),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !isDesktop) {
      ForegroundServiceManager.pingAlive();
      onClipboardChanged();
      unawaited(_drainQueue());
      // Re-check photo access: the user may have just returned from granting
      // full access via the "Fix" banner, which should now clear it.
      unawaited(_startScreenshotSync());
    }
  }

  /// Push text AND images the background native code captured while the UI was
  /// away (focus-trick text + the MediaStore screenshot observer). Engine dedup
  /// absorbs repeats.
  Future<void> _drainQueue() async {
    for (final item in await ClipQueue.drain()) {
      if (_disposed) return;
      if (item.isImage) {
        await _pushLocalImage(item.imageBytes!, mime: item.mime);
      } else {
        await _pushLocal(item.text!);
      }
    }
  }


  @override
  void onClipboardChanged() async {
    // Image first: a screenshot or copied image file can also carry a text /
    // file-path representation, and we must sync the image — not the path.
    // Gallery-style copies hold only a content:// URI, invisible to
    // super_clipboard — the native fallback resolves those (Android only).
    String? clipMime;
    var png = await ImageClipboard.read();
    if (png == null) {
      final uriImage = await ShareChannel.readClipImage();
      if (uriImage != null) {
        png = uriImage.bytes;
        clipMime = uriImage.mime;
      }
    }
    if (png != null) {
      _handledText = null; // clipboard is an image now — the text guard is stale
      final fp = await ImageClipboard.fingerprint(png);
      // Our own echo of an image we just applied — matched by the format-
      // agnostic fingerprint registered up front on the incoming path (so it
      // holds even after the OS re-encodes the read-back). Compare rather than
      // blindly bless the pending read: a DIFFERENT image copied before the
      // echo arrives (the window can be minutes on Android — receive while
      // backgrounded, read on resume) must still sync. An undecodable read-back
      // (fp == null) inside the just-wrote window is treated as the echo to
      // avoid a re-upload loop.
      final expectingEcho = _incomingImagePending;
      _incomingImagePending = false;
      if (fp != null && fp == _handledImageFp) return;
      if (expectingEcho && fp == null) return;
      _handledImageFp = fp;
      await _pushLocalImage(png, mime: clipMime);
      return;
    }
    // Clipboard no longer holds an image — the image guard is stale.
    _incomingImagePending = false;
    _handledImageFp = null;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || text == _handledText) return;
    _handledText = text;
    await _pushLocal(text);
  }

  Future<void> _startScreenshotSync() async {
    final status = await ShareChannel.startScreenshotWatch();
    if (_disposed) return;
    screenshotAccess = status;
    notifyListeners();
  }

  /// Manual capture (phones without background capture, or any device).
  Future<void> addManual(String text) => _pushLocal(text);

  Future<void> _pushLocalImage(Uint8List png, {String? mime}) async {
    if (_disposed) return;
    final until = _suppressImageUntil;
    if (until != null && DateTime.now().isBefore(until)) return; // our own echo
    final engine = _engine;
    final store = _store;
    if (engine == null || store == null) return;
    // Always the original bytes — images sync at full quality, no downscaling.
    final (bytes, outMime) = ImageClipboard.prepareForRelay(png, mime: mime);
    final actions = await engine.onLocalImage(base64Encode(bytes), mime: outMime);
    for (final a in actions) {
      if (a is UploadClip) {
        await store.append(a.clip.copyWith(device: _deviceName));
      }
    }
  }

  Future<void> _pushLocal(String text) async {
    if (_disposed) return;
    final engine = _engine;
    final store = _store;
    if (engine == null || store == null) return;
    final actions = await engine.onLocalClip(
      ClipEvent(text: text, byteSize: utf8.encode(text).length),
    );
    for (final a in actions) {
      if (a is UploadClip) {
        await store.append(a.clip.copyWith(device: _deviceName));
      }
    }
  }

  /// Tap-to-apply: put an existing history item back on the system clipboard.
  /// It must NOT re-upload — it is already in the room. So first record it as
  /// last-applied (before writing, so the persisted hash is in place when the
  /// re-capture drains): on Android the write pops the "Copied" toast that our
  /// AccessibilityService treats as a copy, and on desktop the clipboard
  /// watcher fires — both would otherwise re-broadcast a duplicate. The
  /// engine's echo guard (Rule 2b, persisted + cross-isolate) then drops it.
  /// Images also prime the format-agnostic fingerprint so a re-encoded
  /// read-back (macOS hands a JPEG back as PNG) is still caught on the watcher
  /// path; text primes the exact-match guard.
  Future<void> applyItem(HistoryItem item) async {
    await _engine?.noteApplied(item.hash);
    if (item.isImage && item.imageBytes != null) {
      _handledImageFp = await ImageClipboard.fingerprint(item.imageBytes!);
      await ImageClipboard.write(item.imageBytes!);
    } else {
      _handledText = item.text;
      await _historyStore?.applyItem(item);
    }
  }

  /// Delete the given history items (by content hash) everywhere in the room.
  Future<void> deleteItems(Iterable<HistoryItem> items) async {
    if (_disposed) return;
    await _store?.deleteHashes(items.map((i) => i.hash));
  }

  /// Clear the whole synced history for every device.
  Future<void> clearAll() async {
    if (_disposed) return;
    await _store?.clearAll();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _uiPing?.cancel();
    _macShots?.stop();
    ShareChannel.listen();
    if (_watching) {
      clipboardWatcher.removeListener(this);
      clipboardWatcher.stop();
    }
    _historySub?.cancel();
    _incomingSub?.cancel();
    _connectedSub?.cancel();
    _store?.close();
    super.dispose();
  }
}
