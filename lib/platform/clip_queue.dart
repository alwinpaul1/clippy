import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One captured clipboard item drained from the queue: text or an image.
/// [name] is the source file's basename — requeue() writes an undelivered
/// item back under its ORIGINAL name, preserving capture order (a fresh
/// timestamp would re-order old content after newer captures) and making the
/// write idempotent across the two draining isolates.
class ClipQueueItem {
  final String? text;
  final Uint8List? imageBytes;
  final String? mime;
  final String? name;
  const ClipQueueItem.text(String this.text, {this.name})
      : imageBytes = null,
        mime = null;
  const ClipQueueItem.image(Uint8List this.imageBytes, String this.mime,
      {this.name})
      : text = null;
  bool get isImage => imageBytes != null;
}

/// Drains clips the background native code (ClipboardA11yService: focus-trick
/// text + a MediaStore observer for screenshots) captured to filesDir/clip_queue.
/// Text lands as `<ts>.txt`, images as `<ts>.png|jpg|webp|gif`. Consumed by the
/// app on resume and by the foreground service; the sync engine's dedup makes
/// double-drains harmless. No-op off Android.
abstract class ClipQueue {
  static Directory? _cachedDir;

  /// Test hook: overrides the (Android-only) queue directory so the queue
  /// logic is exercisable in host unit tests.
  @visibleForTesting
  static Directory? debugDir;

  static const _imageMimes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };

  static Future<Directory?> _dir() async {
    if (debugDir != null) return debugDir;
    if (kIsWeb || !Platform.isAndroid) return null;
    if (_cachedDir != null) return _cachedDir;
    try {
      final base = await getApplicationSupportDirectory(); // == Context.filesDir
      _cachedDir = Directory('${base.path}/clip_queue');
      return _cachedDir;
    } catch (_) {
      return null;
    }
  }

  // Processing a clip can fail two very different ways, and treating them the
  // same is how you delete a user's backlog:
  //
  //  * GLOBAL/transient — the engine's prefs write fails (disk full: exactly
  //    what a 200MB queue causes), the crypto box is unusable, the isolate is
  //    out of memory. EVERY item fails, not one. The only safe response is to
  //    put the clip back, stop draining, and try again LATER.
  //  * PER-ITEM — one payload is genuinely unprocessable.
  //
  // They are indistinguishable at the throw site, so time is the discriminator:
  // an item is only suspected of being poison once it has failed on separate
  // drains, minutes apart — never three times in one loop, milliseconds apart.
  // And a suspected-poison clip is QUARANTINED, never deleted: it goes to
  // `<name>.dead` where it stops blocking the queue but still exists.
  static const maxItemFailures = 3;
  static final Map<String, int> _failures = {};
  // Every clip we have EVER failed on, blamed or not. Strikes only accrue with
  // evidence, so _failures alone cannot answer "have we tried this clip?" — and
  // that question is what decides whether a cooldown applies. Without it, a clip
  // we cannot convict looks untried, skips its own hold, and spins.
  static final Set<String> _tried = {};

  /// After a failed drain, hold off before touching the queue again. Without
  /// this the requeue's rename re-fires the inotify watcher, which re-drains
  /// instantly, which fails again — a hot loop pinning the CPU.
  static DateTime? _cooldownUntil;
  static int _drainFailures = 0;

  static bool get inCooldown {
    final until = _cooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// Every clip we have failed on. A drain running under a cooldown must skip
  /// these: the hold exists to stop us re-reading and re-writing a backlog we
  /// already know fails, and one fresh copy must not drag all 200 of them back
  /// through the disk first.
  static Set<String> get triedNames => Set.unmodifiable(_tried);

  /// Is there a clip on disk we have NEVER failed on?
  ///
  /// The cooldown exists to stop us hammering a broken engine (or re-reading a
  /// jam) — it must never make the user's NEXT copy wait behind it. A clip with
  /// no strike history has never been tried, so the hold does not apply to it.
  static DateTime? _untriedAt;
  static bool _untriedCache = false;

  static Future<bool> hasUntriedWork() async {
    // A failed drain requeues every clip, and each write fires the inotify
    // watcher — hundreds of run() entries within milliseconds, each of which
    // would otherwise list the whole directory. One listing per burst is enough.
    final last = _untriedAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(milliseconds: 300)) {
      // Short on purpose: the inotify burst from a failed drain's requeues lands
      // within milliseconds, so this still collapses ~400 listings into one —
      // but a stale `false` must never make a clip the user JUST copied wait for
      // the service's next 10s tick.
      return _untriedCache;
    }
    final dir = await _dir();
    if (dir == null) return false;
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name.startsWith(_beatPrefix) ||
            name.endsWith('.part') ||
            name.endsWith('.dead')) {
          continue;
        }
        if (!_tried.contains(name)) {
          _untriedAt = DateTime.now();
          return _untriedCache = true;
        }
      }
    } catch (_) {}
    _untriedAt = DateTime.now();
    return _untriedCache = false;
  }

  /// A drain failed: hold off before touching the queue again.
  ///
  /// [escalate] doubles the hold each time, up to 4 minutes — right when the
  /// ENGINE is down, so a persistent fault costs one attempt a minute instead of
  /// a spinning core. It is WRONG when the engine is proven healthy and only a
  /// bad clip failed: the hold then exists solely to stop the requeue's inotify
  /// event from spinning, and escalating it would make every GOOD clip wait
  /// minutes to sync because one clip happens to be unprocessable.
  static void noteDrainFailure({bool escalate = true}) {
    if (!escalate) {
      _cooldownUntil = DateTime.now().add(const Duration(seconds: 15));
      return;
    }
    _drainFailures++;
    final secs = (15 * (1 << (_drainFailures - 1).clamp(0, 4))).clamp(15, 240);
    _cooldownUntil = DateTime.now().add(Duration(seconds: secs));
  }

  static void noteDrainSuccess() {
    _drainFailures = 0;
    _cooldownUntil = null;
  }

  /// The escalation level of the backoff. A drain that observed nothing must
  /// not reset this — an empty directory is not evidence that anything works
  /// (the other isolate may be mid-batch, having already deleted the files).
  @visibleForTesting
  static int get drainFailures => _drainFailures;

  /// Let the hold expire WITHOUT forgiving the failures, so a test can drive
  /// the next drain without waiting out a real cooldown.
  @visibleForTesting
  static void expireCooldownForTests() => _cooldownUntil = null;

  /// Record that [name] failed, and report whether it has now failed on enough
  /// SEPARATE runs to be given up on (the caller parks it).
  ///
  /// This is only ever called when the engine PROVED itself during the run —
  /// something else was delivered — so the failure really is this clip's. A
  /// failure with nothing delivered is indistinguishable from a broken engine
  /// and must never be counted: that is how a backlog gets destroyed.
  /// Remember that [name] failed, whether or not there was evidence to blame it.
  static void noteAttemptFailed(String? name) {
    if (name == null) return;
    // The cap MUST exceed the queue's own file bound ([maxQueueFiles]). Evicting
    // a name makes that clip look UNTRIED again, which makes hasUntriedWork()
    // true, which bypasses the cooldown — so with a backlog bigger than the cap
    // the hold would never apply and the requeue->inotify->drain spin returns.
    // enforceBound keeps the queue at ~200 files, so this is never reached in
    // practice; it is a memory backstop, not a working limit.
    if (_tried.length > 5000) _tried.remove(_tried.first);
    _tried.add(name);
  }

  static bool noteItemFailure(String? name) {
    if (name == null) return false;
    // Evict the OLDEST entries rather than wiping the map: a clear would reset
    // everyone's strikes partway through a big jam, so no clip could ever reach
    // three and the jam would be unparkable forever.
    while (_failures.length > 500) {
      _failures.remove(_failures.keys.first);
    }
    final n = (_failures[name] ?? 0) + 1;
    _failures[name] = n;
    if (n >= maxItemFailures) {
      _failures.remove(name);
      return true;
    }
    return false;
  }

  static void clearFailures(String? name) {
    if (name == null) return;
    _failures.remove(name);
    _tried.remove(name); // it worked — it is not a known-bad clip any more
  }

  /// Clear the static machine between tests. Strike counters and cooldowns are
  /// process-wide, so without this one test's failures silently poison the
  /// next test's clips — which is exactly how two of these tests came to pass
  /// for the wrong reason.
  @visibleForTesting
  static void resetForTests() {
    _boundNextAt = null;
    _failures.clear();
    _tried.clear();
    _untriedAt = null;
    _untriedCache = false;
    _cooldownUntil = null;
    _drainFailures = 0;
    _lastBeat = null;
  }

  /// Park a clip we have given up on. The clip is already back on disk (a
  /// failure is requeued the moment it happens), so this is an atomic RENAME to
  /// `<name>.dead` — nothing is rewritten, nothing is held in memory, and a
  /// failure here leaves the clip exactly where it was: still queued. It stops
  /// blocking the queue but is never destroyed; [enforceBound] reaps it after a
  /// day.
  static Future<bool> parkFile(String? name) async {
    if (name == null || name.contains('/')) return false;
    final dir = await _dir();
    if (dir == null) return false;
    try {
      File('${dir.path}/$name').renameSync('${dir.path}/$name.dead');
      debugPrint('ClipQueue: parked unprocessable clip $name');
      return true;
    } catch (_) {
      return false; // still on the queue — we simply could not park it
    }
  }

  /// How much a single drain may hold in memory at once. The queue's own bound
  /// is 200MB of DISK, and every drained item is materialized as bytes in a
  /// list — an hours-long backlog (the service died; captures kept landing)
  /// would otherwise be read in one go and OOM the app at the worst possible
  /// moment: launch. Whatever doesn't fit stays on disk, oldest-first, and the
  /// next drain takes the next batch.
  /// A file at or above this size gets a drain batch to ITSELF (the cap below
  /// stops the batch before adding a second file). QueueDrainer reads this: a
  /// clip that is structurally always alone can never have same-batch evidence,
  /// so it needs a different standard of proof.
  ///
  /// Readable anywhere; writable only by tests. Promoting it to a plain mutable
  /// static would let any future production line silently re-batch the queue for
  /// the life of the process, with the analyzer saying nothing.
  static int get maxDrainBytes => _maxDrainBytes;
  @visibleForTesting
  static set maxDrainBytes(int v) => _maxDrainBytes = v;
  static int _maxDrainBytes = 24 << 20;
  @visibleForTesting
  static int maxDrainFiles = 30;

  /// [skip] holds the basenames of clips that already failed during this drain
  /// run. They stay ON DISK (never held in RAM, never at risk from a process
  /// kill) but are stepped over, so a jam at the head of the queue can never
  /// starve whatever is behind it — at any size.
  static Future<List<ClipQueueItem>> drain({Set<String> skip = const {}}) async {
    final dir = await _dir();
    if (dir == null) return const [];
    try {
      if (!dir.existsSync()) return const [];
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => !f.uri.pathSegments.last.startsWith(_beatPrefix))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) return const [];
      _beat(dir); // tell the other isolate's enforceBound to stand down
      final items = <ClipQueueItem>[];
      var bytes = 0;
      for (final f in files) {
        final ext = f.path.split('.').last.toLowerCase();
        // Images are staged as `<name>.part` then renamed in, so a `.part`
        // seen mid-rename is incomplete — the next drain gets it. But a rename
        // that never completed (writer killed, rename failed) would otherwise
        // orphan the file forever — reap it once it's clearly stale.
        if (ext == 'part') {
          _reapIfStale(f);
          continue;
        }
        // A quarantined clip is parked, not queued — never re-read it (it would
        // come back as garbage "text" and fail forever).
        if (ext == 'dead') continue;
        if (skip.contains(f.uri.pathSegments.last)) continue; // failed already
        // Batch cap: stop BEFORE consuming the file, so it stays on disk (the
        // only crash-proof copy) for the next pass. Never cap at zero items —
        // one clip larger than the budget must still make progress.
        if (items.isNotEmpty &&
            (items.length >= maxDrainFiles || bytes >= _maxDrainBytes)) {
          break;
        }
        final mime = _imageMimes[ext];
        final item =
            mime != null ? await _drainImage(f, mime) : await _drainText(f);
        if (item != null) {
          items.add(item);
          bytes += item.imageBytes?.length ?? item.text?.length ?? 0;
        }
      }
      return items;
    } catch (_) {
      return const [];
    }
  }

  static Future<ClipQueueItem?> _drainText(File f) async {
    String t;
    try {
      t = await f.readAsString();
    } catch (_) {
      // A read can fail transiently — an OOM decoding a big image in the
      // memory-tight service isolate, an EIO on flaky flash — so the file is
      // LEFT ALONE: the next drain (or the other isolate, which may have the
      // memory) gets it. It is only marked tried, because a file that cannot be
      // read is not "untried work" and must not turn every cooldown into a
      // no-op. NEVER reap it here: mtime is when the clip was WRITTEN, not how
      // long we have failed to read it, so an age gate would delete a perfectly
      // good screenshot captured an hour ago on its first read error.
      noteAttemptFailed(f.uri.pathSegments.last);
      return null;
    }
    if (t.isEmpty) {
      _reapIfStale(f);
      return null;
    }
    try {
      await f.delete();
    } catch (_) {}
    return ClipQueueItem.text(t, name: f.uri.pathSegments.last);
  }

  static Future<ClipQueueItem?> _drainImage(File f, String mime) async {
    Uint8List bytes;
    try {
      bytes = await f.readAsBytes();
    } catch (_) {
      // See _drainText: marked tried, but NEVER deleted — a big image that OOMs
      // in this isolate may well decode in the other one.
      noteAttemptFailed(f.uri.pathSegments.last);
      return null;
    }
    if (bytes.isEmpty) {
      _reapIfStale(f);
      return null;
    }
    try {
      await f.delete();
    } catch (_) {}
    return ClipQueueItem.image(bytes, mime, name: f.uri.pathSegments.last);
  }

  // A drain now leaves its un-taken tail on disk between batches (that is the
  // point of the batch cap) — and enforceBound prunes OLDEST-first, i.e.
  // exactly the files the drain is about to deliver, from an isolate whose own
  // link may be down. This heartbeat says "a drain is live in SOME isolate".
  //
  // It is only ever refreshed, NEVER deleted — that is what killed the old
  // drain.lock: whichever drain finished first deleted the lock out from under
  // the other one. Staleness expires it instead.
  // ONE FILE PER ISOLATE. A single shared beat could never be released: whoever
  // finished first would delete it out from under the other's live drain (that
  // is what killed the old drain.lock). With a file each, an isolate releases
  // only its OWN — no race — and enforceBound simply stands down while ANY beat
  // is fresh. Without a release, a drain's own beat keeps standing the pruner
  // down for a whole minute after it ends, and with the service draining every
  // 10s that means the queue bound never runs at all.
  static const _beatPrefix = 'drain.beat';
  static final String _beatName =
      '$_beatPrefix.${DateTime.now().microsecondsSinceEpoch}';
  static const _beatFresh = Duration(minutes: 1);
  // A beat from an isolate that died mid-drain would otherwise hold the pruner
  // off forever; reap it once no live drain could possibly still own it.
  static const _beatStale = Duration(minutes: 5);
  static DateTime? _lastBeat;

  /// Refresh the "a drain is live" heartbeat. Callers must keep calling this
  /// WHILE they upload — a batch of large images can take minutes, far longer
  /// than [_beatFresh], and a heartbeat that goes stale mid-drain lets the other
  /// isolate prune the very tail we are working through. Self-throttled, so
  /// calling it per item costs nothing.
  static Future<void> beat() async {
    final dir = await _dir();
    if (dir == null) return;
    _beat(dir);
  }

  static void _beat(Directory dir) {
    final now = DateTime.now();
    final last = _lastBeat;
    // Throttled: a 200-file drain must not mean 200 flash writes.
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastBeat = now;
    try {
      File('${dir.path}/$_beatName').writeAsStringSync('');
    } catch (_) {}
  }

  /// This isolate's drain is over. Deleting only OUR beat is always safe — the
  /// other isolate owns a different file — and it is what lets enforceBound run
  /// at all: a beat left behind stands the pruner down for a full minute, and
  /// the service drains every 10 seconds.
  static Future<void> releaseBeat() async {
    if (_lastBeat == null) return; // we never beat — nothing to let go of
    final dir = await _dir();
    if (dir == null) return;
    _lastBeat = null;
    try {
      File('${dir.path}/$_beatName').deleteSync();
    } catch (_) {}
  }

  /// Is a drain live in ANY isolate? Takes the directory listing the caller
  /// already has — enforceBound needs it anyway, and listing twice per pass is
  /// pure I/O on the phone.
  static bool _drainLive(List<File> entries) {
    final now = DateTime.now();
    try {
      for (final f in entries) {
        if (!f.uri.pathSegments.last.startsWith(_beatPrefix)) continue;
        final age = now.difference(f.statSync().modified);
        if (age < _beatFresh) return true;
        // Left behind by an isolate that died mid-drain.
        if (age > _beatStale) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return false; // no live heartbeat — nothing is draining
  }

  /// Whether [f]'s last modification is older than [age]. Treats a
  /// stat failure (file vanished under a concurrent delete) as "not older" so
  /// callers simply skip it.
  static bool _olderThan(File f, Duration age) {
    try {
      return DateTime.now().difference(f.statSync().modified) > age;
    } catch (_) {
      return false;
    }
  }

  /// A file that stays empty (writer killed mid-write) is re-listed on every
  /// drain forever — reap it after a grace window.
  static void _reapIfStale(File f) {
    try {
      if (_olderThan(f, const Duration(seconds: 30))) f.deleteSync();
    } catch (_) {}
  }

  /// Put a drained item BACK on disk under its ORIGINAL filename. drain()
  /// consumes the file before the send happens, so if the relay link dies
  /// mid-drain the disk copy — the only one that survives a process kill —
  /// would be gone. Both types go through .part+rename staging so a
  /// concurrent drain (or the inotify watcher this write triggers) never
  /// reads a half-written file. Reusing the original name preserves capture
  /// order in the drain's path sort and makes concurrent requeues of the
  /// same item (both isolates drained the same file) collide harmlessly on
  /// identical content. Best-effort: items the drain loop never reached have
  /// NO other copy, so a failed write here is a genuine (rare) loss.
  static Future<void> requeue(ClipQueueItem item) async {
    final name = item.name;
    if (name == null || name.contains('/')) return; // only drain-produced items
    final dir = await _dir();
    if (dir == null) return;
    try {
      dir.createSync(recursive: true);
      final part = File('${dir.path}/$name.part');
      if (item.isImage) {
        await part.writeAsBytes(item.imageBytes!);
      } else {
        await part.writeAsString(item.text!);
      }
      try {
        part.renameSync('${dir.path}/$name');
      } catch (_) {
        part.deleteSync(); // don't leave an orphan blocking the reaper
      }
    } catch (_) {
      // Disk full / dir gone — nothing more we can do without the file.
    }
  }

  /// Requeue every item, preserving order. Used when a drain must abort
  /// mid-way (link died, controller disposed) with items already consumed.
  static Future<void> requeueAll(Iterable<ClipQueueItem> items) async {
    for (final item in items) {
      await requeue(item);
    }
  }

  // The queue only grows while the relay is unreachable (drains are gated on
  // a confirmed link), and nothing else bounds it — a device that stays
  // paired-but-unconnected would accumulate captures (multi-MB images
  // included) without limit. Mutable only so tests can shrink the fixture.
  @visibleForTesting
  static int maxQueueFiles = 200;
  @visibleForTesting
  static int maxQueueBytes = 200 << 20;

  /// How long a queue file must sit untouched before the bound may prune it.
  /// This — a per-file property, not shared lock state — is the cross-isolate
  /// safety: anything a drain just requeued (or a writer just staged) carries
  /// a fresh mtime and is structurally unprunable, with no heartbeat for a
  /// concurrent drain to delete out from under the other isolate. An OLD
  /// over-bound file can still be pruned while the other isolate's drain is
  /// mid-flight — but pruning it is exactly the bound's stated policy.
  static const _pruneMinAge = Duration(minutes: 1);

  /// Drop the oldest queue files while over the count/byte bound. `.part`
  /// staging files are exempt from the bound (they are mid-write), but stale
  /// ones are reaped here too: while offline — the only time this runs —
  /// drain() never runs, so its reaper can't.
  // The bound is a slow-moving condition, but the service ticks the drain (and
  // this) every 10s: listing + stat-ing 200 files that often is pure battery.
  // Two different waits, because they answer two different questions:
  //  * a pass that RAN has just settled the queue — nothing can change fast
  //    enough to matter for a minute;
  //  * a pass that stood down for a live drain settled nothing, so it must come
  //    back soon — but not on every tick for the length of a long drain.
  static DateTime? _boundNextAt;
  static const _boundAfterPass = Duration(seconds: 60);
  static const _boundAfterStandDown = Duration(seconds: 15);

  static Future<void> enforceBound() async {
    final next = _boundNextAt;
    if (next != null && DateTime.now().isBefore(next)) return;
    final dir = await _dir();
    if (dir == null) return;
    try {
      if (!dir.existsSync()) return;
      final entries = dir.listSync().whereType<File>().toList();
      // A drain is live SOMEWHERE (this isolate's link being down says nothing
      // about the other's). Since the batch cap leaves its tail on disk between
      // batches, and we prune oldest-first, pruning now would delete precisely
      // the clips it is about to deliver.
      //
      // Standing down does NOT spend the throttle: otherwise one unlucky
      // overlap with a live drain would push the next pruning pass a whole
      // minute past the moment the queue actually needed it.
      if (_drainLive(entries)) {
        _boundNextAt = DateTime.now().add(_boundAfterStandDown);
        return;
      }
      _boundNextAt = DateTime.now().add(_boundAfterPass);
      // The bound is judged against EVERYTHING on disk (that's the real
      // usage), but only files past the age gate are eligible for deletion —
      // fresh writes protect themselves by mtime.
      var count = 0;
      var total = 0;
      final prunable = <(File, int)>[];
      for (final f in entries) {
        if (f.uri.pathSegments.last.startsWith(_beatPrefix)) continue; // not a clip
        if (f.path.endsWith('.part')) {
          _reapIfStale(f);
          continue;
        }
        // Quarantined clips are exempt from the bound (they aren't queued work)
        // but must not accumulate forever.
        if (f.path.endsWith('.dead')) {
          try {
            if (_olderThan(f, const Duration(days: 1))) f.deleteSync();
          } catch (_) {}
          continue;
        }
        int size;
        try {
          size = f.statSync().size;
        } catch (_) {
          continue; // vanished between list and stat (concurrent delete)
        }
        count++;
        total += size;
        if (_olderThan(f, _pruneMinAge)) prunable.add((f, size));
      }
      prunable.sort((a, b) => a.$1.path.compareTo(b.$1.path)); // oldest first
      for (final (f, size) in prunable) {
        if (count <= maxQueueFiles && total <= maxQueueBytes) break;
        try {
          f.deleteSync();
        } catch (_) {
          // Failed with the file still present: NOT freed — counting it
          // would end the loop with the disk still over its bound. A file
          // that vanished concurrently is genuinely gone and still counts.
          var stillThere = true;
          try {
            stillThere = f.existsSync();
          } catch (_) {}
          if (stillThere) continue;
        }
        count--;
        total -= size;
      }
    } catch (_) {}
  }

  /// Instant sync: fires the moment native code writes a captured clip (inotify
  /// via Directory.watch). This is on filesDir (app-private ext4), where
  /// inotify is reliable — unlike external storage's FUSE mount. Returns null
  /// off Android; callers keep a slow poll as a fallback either way.
  static Future<Stream<void>?> watch() async {
    final dir = await _dir();
    if (dir == null) return null;
    try {
      dir.createSync(recursive: true); // must exist before watching
      // All events: text is a create/modify, images are renamed in (a move) —
      // drain is idempotent, so extra triggers are cheap.
      return dir.watch();
    } catch (_) {
      return null;
    }
  }
}
