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
import '../platform/flutter_clipboard_writer.dart';
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

  List<HistoryItem> history = const [];
  bool ready = false;
  bool connected = false;

  bool get isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  Future<void> start(PairingKey pairing) async {
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
        if (a is ApplyToClipboard) await _writer.setText(a.text);
        // OfferRestore is intentionally not auto-applied.
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
    }

    ready = true;
    notifyListeners();
  }

  @override
  void onClipboardChanged() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) await _pushLocal(text);
  }

  /// Manual capture (phones without background capture, or any device).
  Future<void> addManual(String text) => _pushLocal(text);

  Future<void> _pushLocal(String text) async {
    final engine = _engine;
    final store = _store;
    if (engine == null || store == null) return;
    final actions = await engine.onLocalClip(
      ClipEvent(text: text, byteSize: utf8.encode(text).length),
    );
    for (final a in actions) {
      if (a is UploadClip) await store.append(a.clip);
    }
  }

  Future<void> applyItem(HistoryItem item) async =>
      _historyStore?.applyItem(item);

  @override
  void dispose() {
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
