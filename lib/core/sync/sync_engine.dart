import '../crypto/crypto_box.dart';
import '../models/clip_event.dart';
import '../models/remote_clip.dart';
import 'state_store.dart';
import 'sync_action.dart';

/// The Clippy sync state machine (spec §7). Pure decision logic: it consumes
/// local clipboard events and remote snapshots and returns the actions a
/// platform should perform. Owns the echo-guard, freshness gate, and dedup.
class SyncEngine {
  final CryptoBox _crypto;
  final StateStore _state;
  final String _selfDeviceId;
  final DateTime Function() _clock;
  final int _sizeCapBytes;
  final Duration _freshnessWindow;
  final Duration _echoWindow;

  // Persisted-across-restarts dedup key, cached in memory after first load.
  String? _lastAppliedHash;
  bool _lastAppliedLoaded = false;

  // One-shot echo suppression: set when we apply a remote clip, consumed by
  // the next matching local event, and time-boxed by _echoWindow.
  String? _expectedEchoHash;
  DateTime? _expectedEchoExpiry;

  // Freshness gate applies only to the first considered snapshot of a session.
  bool _firstSnapshotConsidered = false;

  SyncEngine({
    required CryptoBox crypto,
    required StateStore state,
    required String selfDeviceId,
    required DateTime Function() clock,
    int sizeCapBytes = 102400,
    Duration freshnessWindow = const Duration(seconds: 60),
    Duration echoWindow = const Duration(seconds: 2),
  })  : _crypto = crypto,
        _state = state,
        _selfDeviceId = selfDeviceId,
        _clock = clock,
        _sizeCapBytes = sizeCapBytes,
        _freshnessWindow = freshnessWindow,
        _echoWindow = echoWindow;

  Future<void> _ensureLoaded() async {
    if (_lastAppliedLoaded) return;
    _lastAppliedHash = await _state.readLastAppliedHash();
    _lastAppliedLoaded = true;
  }

  Future<void> _setLastApplied(String hash) async {
    _lastAppliedHash = hash;
    _lastAppliedLoaded = true;
    await _state.writeLastAppliedHash(hash);
  }

  /// Spec §7 — On local clipboard change.
  Future<List<SyncAction>> onLocalClip(ClipEvent event) async {
    // Rule 1: ignore non-text, concealed/sensitive, or oversize clips.
    if (!event.isText || event.isConcealed || event.byteSize > _sizeCapBytes) {
      return const [];
    }
    final text = event.text!;
    final h = await _crypto.fingerprint(text);

    // Rule 2: one-shot, time-boxed echo suppression.
    if (_expectedEchoHash != null &&
        h == _expectedEchoHash &&
        _clock().isBefore(_expectedEchoExpiry!)) {
      _expectedEchoHash = null;
      _expectedEchoExpiry = null;
      return const [];
    }

    // Rule 3: seal and upload.
    final clip = await _crypto.seal(text, source: _selfDeviceId);
    await _setLastApplied(h);
    return [UploadClip(clip)];
  }

  /// Spec §7 — On remote snapshot.
  Future<List<SyncAction>> onRemoteSnapshot(RemoteClip clip) async {
    // Rule 1: never react to our own writes.
    if (clip.source == _selfDeviceId) return const [];

    // Rule 2: already applied (also absorbs reconnect / cold-start re-delivery).
    await _ensureLoaded();
    if (clip.hash == _lastAppliedHash) return const [];

    // From here this counts as a "considered" snapshot for the freshness gate.
    final isFirstConsidered = !_firstSnapshotConsidered;
    _firstSnapshotConsidered = true;

    // Rule 3: cold-start / fresh-install protection — do not clobber the live
    // clipboard with a stale clip on the first considered snapshot.
    if (isFirstConsidered &&
        _clock().difference(clip.timestamp) > _freshnessWindow) {
      final text = await _crypto.open(clip);
      await _setLastApplied(clip.hash);
      return [OfferRestore(text)];
    }

    // Rule 4: apply, and arm one-shot echo suppression for the local watcher.
    final text = await _crypto.open(clip);
    _expectedEchoHash = clip.hash;
    _expectedEchoExpiry = _clock().add(_echoWindow);
    await _setLastApplied(clip.hash);
    return [ApplyToClipboard(text)];
  }
}
