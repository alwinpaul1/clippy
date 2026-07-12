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
    try {
      await ClipQueue.beat();
      // drain() returns a bounded BATCH (a long-dead service leaves a huge
      // backlog, and reading it all at once would OOM the app at launch), so
      // keep going until the disk is dry.
      while (canContinue()) {
        i = 0;
        items = await ClipQueue.drain();
        if (items.isEmpty) break;

        // Attempt the WHOLE batch before judging anything. A failure alone says
        // nothing: the engine (a prefs write, the crypto box, an allocation)
        // fails for every clip alike, so one failure looks exactly like a bad
        // clip. What tells them apart is whether ANYTHING ELSE went through.
        var delivered = 0;
        final failed = <ClipQueueItem>[];
        for (; i < items.length; i++) {
          if (!canContinue()) return; // finally requeues items[i..]
          final item = items[i];
          try {
            await process(item);
            ClipQueue.clearFailures(item.name);
            delivered++;
          } catch (_) {
            failed.add(item); // held in memory; disposed of below, once
          }
        }

        if (failed.isEmpty) continue; // clean batch — go get the next one

        if (delivered == 0) {
          // NOTHING worked: presume the ENGINE is down, not the clips. Put the
          // batch back untouched and back off — never burn through the queue
          // proving a broken engine is still broken.
          //
          // One exception, or the queue could jam forever: strike ONLY the head
          // clip. If it is genuinely unprocessable and sits alone in the queue,
          // nothing will ever succeed to prove the engine works, so without this
          // it would block every drain for good. ClipQueue withholds judgement
          // until such a clip has been failing for poisonMinAge, which a
          // transient outage never reaches.
          final head = failed.first;
          if (ClipQueue.noteItemFailure(head.name, engineProven: false)) {
            await ClipQueue.quarantine(head); // parked, never destroyed
            await ClipQueue.requeueAll(failed.skip(1).toList());
          } else {
            await ClipQueue.requeueAll(failed);
          }
          ClipQueue.noteDrainFailure();
          return;
        }

        // Something DID go through, so the engine works and these clips are
        // individually suspect. ONE strike each — and because the run stops
        // here, the next strike can only come from a LATER run, behind the
        // cooldown. That time separation is the whole point: three strikes in
        // one loop would quarantine a backlog that hit a two-second hiccup.
        for (final f in failed) {
          if (ClipQueue.noteItemFailure(f.name, engineProven: true)) {
            await ClipQueue.quarantine(f); // parked, never destroyed
          } else {
            await ClipQueue.requeue(f);
          }
        }
        ClipQueue.noteDrainFailure(); // retry the stragglers later, not now
        return;
      }
      ClipQueue.noteDrainSuccess();
    } finally {
      beat.cancel();
      // Any early exit (link lost, disposal) leaves the un-attempted tail
      // holding the only copy of clips whose files drain() already deleted.
      if (i < items.length) await ClipQueue.requeueAll(items.sublist(i));
      _draining = false;
    }
  }
}
