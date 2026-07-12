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
///  * A failure with NOTHING delivered yet is presumed GLOBAL, not specific to
///    the clip: every throw comes from the engine (a prefs write, the crypto
///    box, an allocation), and those fail for every item alike. Put the clip
///    back, stop, and back off. Never burn through the queue proving that a
///    broken engine is still broken — that is how you destroy a backlog.
///  * A failure AFTER something was delivered proves the engine works, so the
///    fault is this clip's: set it aside and carry on with the rest.
///  * A clip that fails repeatedly is QUARANTINED (parked as `.dead`), never
///    deleted, and the drain continues past it — one bad clip must not hold
///    the queue hostage.
class QueueDrainer {
  QueueDrainer({required this.process, required this.canContinue});

  /// Deliver one clip. Throwing means "not delivered".
  final Future<void> Function(ClipQueueItem item) process;

  /// False when the link is down or the owner is disposed — the drain stops
  /// and everything undelivered goes back to disk.
  final bool Function() canContinue;

  bool _draining = false;

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
    // Clips that threw, held in memory until they are disposed of (requeued or
    // parked). Declared OUT here so the finally can rescue them: drain() has
    // already deleted their files, so anything still in this list at exit is a
    // clip that exists NOWHERE else.
    var failed = <ClipQueueItem>[];
    try {
      await ClipQueue.beat();
      // drain() returns a bounded BATCH (a long-dead service leaves a huge
      // backlog, and reading it all at once would OOM the app at launch), so
      // keep going until the disk is dry.
      while (canContinue()) {
        i = 0;
        failed = [];
        items = await ClipQueue.drain();
        if (items.isEmpty) break;

        // Attempt the WHOLE batch before judging anything. A single failure
        // says nothing: the engine (a prefs write, the crypto box, an
        // allocation) fails for every clip alike, so a broken engine looks
        // exactly like a bad clip. What tells them apart is whether ANYTHING
        // ELSE got through.
        var delivered = 0;
        for (; i < items.length; i++) {
          if (!canContinue()) return; // finally rescues `failed` AND items[i..]
          final item = items[i];
          try {
            await process(item);
            ClipQueue.clearFailures(item.name);
            delivered++;
          } catch (_) {
            failed.add(item);
          }
        }

        if (failed.isEmpty) {
          // A batch delivered in full: the engine works. THIS is the only
          // evidence that clears the backoff — an empty directory is not (the
          // other isolate may be mid-batch, having already deleted the files).
          ClipQueue.noteDrainSuccess();
          continue;
        }

        if (delivered == 0) {
          // NOTHING worked: presume the ENGINE is down, not the clips. Put the
          // batch back untouched and back off. Never burn through the queue
          // proving a broken engine is still broken.
          //
          // One exception, or the queue could jam forever: a clip that is the
          // ONLY thing in the batch can never have another clip succeed to
          // prove the engine works, so without this it would block every drain
          // for good. Strike it — but ClipQueue withholds judgement until it
          // has been failing for poisonMinAge, which no transient outage
          // reaches. If several clips failed together, that is evidence FOR a
          // global fault, not against any one of them: blame nobody.
          final lone = failed.length == 1 ? failed.first : null;
          if (lone != null &&
              ClipQueue.noteItemFailure(lone.name, engineProven: false)) {
            await _park(lone);
          } else {
            await ClipQueue.requeueAll(failed);
          }
          failed = [];
          ClipQueue.noteDrainFailure();
          return;
        }

        // Something DID go through, so the engine works and these clips are
        // individually suspect. ONE strike each — and the run ENDS here, so the
        // next strike can only come from a LATER run, behind the cooldown.
        // Three strikes inside one loop would quarantine a backlog that merely
        // hit a two-second hiccup.
        for (final f in failed) {
          if (ClipQueue.noteItemFailure(f.name, engineProven: true)) {
            await _park(f);
          } else {
            await ClipQueue.requeue(f);
          }
        }
        failed = [];
        ClipQueue.noteDrainFailure(); // retry the stragglers later, not now
        return;
      }
    } finally {
      beat.cancel();
      // Every exit path, including a link that died mid-batch: anything drained
      // but not yet delivered or disposed of holds the ONLY copy of that clip.
      if (failed.isNotEmpty) await ClipQueue.requeueAll(failed);
      if (i < items.length) await ClipQueue.requeueAll(items.sublist(i));
      _draining = false;
    }
  }

  /// Park a clip we have given up on — and if parking itself fails (the disk is
  /// full, which is the very fault most likely to have caused the failures),
  /// put it back on the queue. Never let "we couldn't save it" become "we
  /// deleted it".
  Future<void> _park(ClipQueueItem item) async {
    if (!await ClipQueue.quarantine(item)) await ClipQueue.requeue(item);
  }
}
