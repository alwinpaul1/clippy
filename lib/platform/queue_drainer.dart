import 'dart:async';

import 'clip_queue.dart';

/// Drains the on-disk clip queue and hands each item to [process].
///
/// This is the queue's FAILURE POLICY, and it lives in one place because both
/// isolates (UI and foreground service) drain the same directory and must
/// behave identically — and because the policy is subtle enough that it has to
/// be testable on its own.
///
/// The rules, and why:
///
///  * Draining CONSUMES the file (it is the only copy that survives a process
///    kill), so anything not delivered must be put back. Every early exit —
///    link lost, disposal, a throw — requeues the remainder.
///  * Failures are held IN MEMORY for the run, not written straight back. That
///    is what lets the drain step OVER a failing clip and reach what is behind
///    it — requeue-immediately means the next drain re-reads the same clip
///    forever and everything behind it starves.
///  * Nothing is judged until the run ends. If NOTHING was delivered anywhere
///    in the run, the ENGINE is presumed broken (every throw comes from it: a
///    prefs write, the crypto box, an allocation — they fail for every clip
///    alike), so the clips go back and NOBODY is blamed. Blaming clips for a
///    broken engine is how you destroy a backlog.
///  * If anything WAS delivered, the engine is proven and the failures really
///    are those clips': one strike each. Three strikes — each from a separate
///    run, behind a cooldown — and the clip is PARKED as `.dead`, never
///    deleted. If parking fails too, it goes back on the queue.
class QueueDrainer {
  QueueDrainer({required this.process, required this.canContinue});

  /// Deliver one clip. Throwing means "not delivered".
  final Future<void> Function(ClipQueueItem item) process;

  /// False when the link is down or the owner is disposed — the drain stops
  /// and everything undelivered goes back to disk.
  final bool Function() canContinue;

  bool _draining = false;

  // Failures are held in RAM for the run, so this is what bounds that. It must
  // exceed one full drain batch (30 files / 24MB), or a batch of failing clips
  // at the head of the queue could never be stepped over — which is exactly the
  // starvation this design exists to prevent.
  static const _maxHeldFailures = 60;
  static const _maxHeldBytes = 32 << 20;

  Future<void> run() async {
    // Overlapping drains would read and upload the same file twice before
    // either deleted it; a cooldown means a recent drain failed and hammering
    // the queue again would just fail the same way.
    if (_draining || ClipQueue.inCooldown || !canContinue()) return;
    _draining = true;
    // Hold the "a drain is live" heartbeat for the WHOLE drain: one oversized
    // image can upload for minutes, and a stale beat lets the other isolate's
    // enforceBound prune the tail we are working through (it prunes
    // oldest-first — exactly the next batches).
    final beat = Timer.periodic(
        const Duration(seconds: 20), (_) => unawaited(ClipQueue.beat()));
    var i = 0;
    var items = const <ClipQueueItem>[];
    // Clips that threw. They are held IN MEMORY for the rest of the run rather
    // than written straight back to disk — that is what lets the drain move on
    // to the NEXT batch instead of re-reading them forever, and it is the only
    // way a clip sitting at the head of the queue can ever stop blocking what
    // is behind it. Because drain() has already deleted their files, anything
    // still in this list at exit exists NOWHERE else: the finally rescues it.
    final failed = <ClipQueueItem>[];
    var failedBytes = 0;
    var delivered = 0;
    try {
      await ClipQueue.beat();
      // drain() returns a bounded BATCH (a long-dead service leaves a huge
      // backlog, and reading it all at once would OOM the app at launch), so
      // keep going until the disk is dry.
      while (canContinue()) {
        i = 0;
        items = await ClipQueue.drain();
        if (items.isEmpty) break;

        // Attempt the WHOLE batch before judging anything. A single failure
        // says nothing: the engine (a prefs write, the crypto box, an
        // allocation) fails for every clip alike, so a broken engine looks
        // exactly like a bad clip. What tells them apart is whether ANYTHING
        // ELSE, anywhere in this run, got through.
        for (; i < items.length; i++) {
          if (!canContinue()) return; // finally rescues `failed` AND items[i..]
          final item = items[i];
          try {
            await process(item);
            ClipQueue.clearFailures(item.name);
            delivered++;
          } catch (_) {
            failed.add(item);
            failedBytes += item.imageBytes?.length ?? item.text?.length ?? 0;
          }
        }
        // Holding failures in memory is bounded: past this, stop and put them
        // back rather than accumulate a backlog in RAM.
        if (failed.length >= _maxHeldFailures || failedBytes >= _maxHeldBytes) {
          break;
        }
      }
    } finally {
      beat.cancel();
      // items[i..] were never attempted (link lost, disposal) — straight back.
      if (i < items.length) await ClipQueue.requeueAll(items.sublist(i));
      // Read this BEFORE _dispose empties the list, or the success check below
      // would fire on a run that failed and undo the backoff _dispose just set.
      final clean = failed.isEmpty;
      await _dispose(failed, engineProven: delivered > 0);
      if (clean && delivered > 0) {
        // A run that delivered everything it touched: the engine works. THIS is
        // the only evidence that clears the backoff — an empty directory is
        // not (the other isolate may be mid-batch, its files already deleted).
        ClipQueue.noteDrainSuccess();
      }
      _draining = false;
    }
  }

  /// Put the run's failures where they belong — exactly once, on every exit.
  ///
  /// [engineProven] is the whole judgement: if ANYTHING was delivered during
  /// this run, the engine works and these clips are individually suspect (one
  /// strike each; three strikes, each from a separate run, parks them). If
  /// nothing was delivered, the engine is presumed down and NOBODY is blamed —
  /// the clips simply go back. Blaming clips for a broken engine is how you
  /// destroy a backlog.
  Future<void> _dispose(List<ClipQueueItem> failed,
      {required bool engineProven}) async {
    if (failed.isEmpty) return;
    for (final f in failed) {
      if (engineProven && ClipQueue.noteItemFailure(f.name)) {
        await _park(f);
      } else {
        await ClipQueue.requeue(f);
      }
    }
    failed.clear();
    ClipQueue.noteDrainFailure(); // something is wrong — don't hammer the queue
  }

  /// Park a clip we have given up on — and if parking itself fails (the disk is
  /// full, which is the very fault most likely to have caused the failures),
  /// put it back on the queue. Never let "we couldn't save it" become "we
  /// deleted it".
  Future<void> _park(ClipQueueItem item) async {
    if (!await ClipQueue.quarantine(item)) await ClipQueue.requeue(item);
  }
}
