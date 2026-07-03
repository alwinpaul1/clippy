import 'dart:async';
import 'dart:convert';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
import '../platform/share_channel.dart';
import 'relay_config.dart';

/// Orchestrates the whole client: pairing key → content keys + room token →
/// relay connection → SyncEngine (apply-latest) + HistoryStore (browsable list).
/// On desktop it auto-captures system-clipboard changes; everywhere it applies
/// incoming clips and exposes the synced history.
class ClipController extends ChangeNotifier with ClipboardListener {
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
  String _deviceName = '';
  // After we write an incoming image to the clipboard, ignore the watcher's
  // resulting change for a moment (PNG round-trips aren't byte-identical, so a
  // content fingerprint can't catch this echo).
  DateTime? _suppressImageUntil;

  List<HistoryItem> history = const [];
  bool ready = false;
  bool connected = false;

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
    _store = WebSocketClipStore.connect(Uri.parse(relayUrl), roomToken);

    _historySub = _store!.history.listen((clips) async {
      history = await _historyStore!.project(clips);
      notifyListeners();
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
            await ImageClipboard.write(jpeg);
          } catch (_) {
            // Corrupt payload — skip.
          }
        } else {
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
    } else {
      // Keep receiving in the background so copies from other devices land on
      // the phone's clipboard without opening Clippy. Android requires a
      // foreground-service notification for this (kept at MIN importance).
      await ForegroundServiceManager.start();
    }

    ready = true;
    notifyListeners();

    // "Send to Clippy" (Android share sheet + text-selection popup) → sync it.
    // One tap, no special permissions; on desktop the channel is absent.
    ShareChannel.listen(
      onText: _pushLocal,
      onImage: (bytes, _) => _pushLocalImage(bytes),
    );
    await ShareChannel.initial(
      onText: _pushLocal,
      onImage: (bytes, _) => _pushLocalImage(bytes),
    );
  }

  @override
  void onClipboardChanged() async {
    // Text first (common + cheap); fall back to an image on the clipboard.
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      await _pushLocal(text);
      return;
    }
    final png = await ImageClipboard.read();
    if (png != null) await _pushLocalImage(png);
  }

  /// Manual capture (phones without background capture, or any device).
  Future<void> addManual(String text) => _pushLocal(text);

  Future<void> _pushLocalImage(Uint8List png) async {
    if (_disposed) return;
    final until = _suppressImageUntil;
    if (until != null && DateTime.now().isBefore(until)) return; // our own echo
    final engine = _engine;
    final store = _store;
    if (engine == null || store == null) return;
    final jpeg = ImageClipboard.downscaleForRelay(png);
    final actions = await engine.onLocalImage(base64Encode(jpeg));
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

  Future<void> applyItem(HistoryItem item) async {
    if (item.isImage && item.imageBytes != null) {
      await ImageClipboard.write(item.imageBytes!);
    } else {
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
