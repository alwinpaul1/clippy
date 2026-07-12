import 'dart:async';

import 'clip_queue.dart';

/// Drains the on-disk clip queue and hands each item to [process].
///
/// This is the queue's FAILURE POLICY. It lives in one place because both
/// isolates (UI and foreground service) drain the same directory and must
/// behave identically — and because it is subtle enough that it has to be
/// testable on its own. Nine review rounds of scar tissue, in three rules:
///
///  * A failure goes BACK TO DISK immediately, and its name goes on a skip list
///    for the rest of the run. Stepping over a clip and holding a clip are
///    different things: holding it in RAM bounds how far you can step (so a big
///    enough jam still starves everything behind it) and makes memory the only
///    copy, where a process kill destroys it. Skipping by name steps over a jam
///    of ANY size while the clip stays safe on disk.
///  * Blame requires evidence, and the evidence is a delivery AFTER the failure.
///    Every throw comes from the engine (a prefs write, the crypto box, an
///    allocation), so a failure on its own is indistinguishable from a broken
///    engine — and blaming clips for a broken engine is how you destroy a
///    backlog. "Something synced earlier in the run" is not enough either: an
///    engine that dies part-way (a disk filling up) delivers first and throws
///    after, which would frame every clip behind the death.
///  * Three strikes, each needing that evidence, and the clip is PARKED: an
///    atomic rename to `<name>.dead`. It stops blocking the queue, is never
///    deleted, and if the rename fails the clip simply stays queued.
class QueueDrainer {
  QueueDrainer({required this.process, required this.canContinue});

  /// Deliver one clip. Throwing means "not delivered".
  final Future<void> Function(ClipQueueItem item) process;

  /// False when the link is down or the owner is disposed — the drain stops and
  /// everything undelivered goes back to disk.
  final bool Function() canContinue;

  bool _draining = false;

  Future<void> run() async {
    // Overlapping drains would read and upload the same file twice before
    // either deleted it; a cooldown means the engine looked broken a moment ago
    // and hammering the queue would just fail the same way.
    if (_draining || ClipQueue.inCooldown || !canContinue()) return;
    _draining = true;
    // Hold the "a drain is live" heartbeat for the WHOLE run: one oversized
    // image can upload for minutes, and a stale beat lets the other isolate's
    // enforceBound prune the tail we are working through (it prunes
    // oldest-first — exactly the next batches).
    final beat = Timer.periodic(
        const Duration(seconds: 20), (_) => unawaited(ClipQueue.beat()));
    // Failed this run: stepped over, but still on disk.
    final skip = <String>{};
    // For each failure, how many clips had been delivered when it failed — it
    // is only answerable if MORE were delivered afterwards.
    final failedAt = <String, int>{};
    var delivered = 0;
    var i = 0;
    var items = const <ClipQueueItem>[];
    try {
      await ClipQueue.beat();
      // drain() returns a bounded BATCH (a long-dead service leaves a huge
      // backlog, and reading it all at once would OOM the app at launch), so
      // keep going until nothing is left that this run hasn't already tried.
      while (canContinue()) {
        i = 0;
        final deliveredBefore = delivered;
        final skippedBefore = skip.length;
        items = await ClipQueue.drain(skip: skip);
        if (items.isEmpty) break;
        for (; i < items.length; i++) {
          if (!canContinue()) return; // finally puts items[i..] back
          final item = items[i];
          try {
            await process(item);
            ClipQueue.clearFailures(item.name);
            delivered++;
          } catch (_) {
            // Straight back to disk: a clip is never the sole property of a
            // process that might be killed. Then step over it for this run.
            await ClipQueue.requeue(item);
            final name = item.name;
            if (name != null) {
              skip.add(name);
              failedAt.putIfAbsent(name, () => delivered);
            }
          }
        }
        // Termination guard. The skip list is what makes the loop finite: every
        // failure is stepped over, so drain() eventually returns nothing. If a
        // batch ever manages to neither deliver nor skip anything, we would
        // re-read it forever — stop instead of spinning the CPU.
        if (delivered == deliveredBefore && skip.length == skippedBefore) break;
      }
    } finally {
      beat.cancel();
      if (i < items.length) await ClipQueue.requeueAll(items.sublist(i));
      await _judge(failedAt, delivered);
      _draining = false;
    }
  }

  /// Decide what the run's failures MEANT, once it is over.
  Future<void> _judge(Map<String, int> failedAt, int delivered) async {
    if (failedAt.isEmpty) {
      // Only a run that actually delivered something is evidence the engine
      // works — an empty directory is not (the other isolate may be mid-batch,
      // its files already deleted).
      if (delivered > 0) ClipQueue.noteDrainSuccess();
      return;
    }
    var blamed = false;
    for (final entry in failedAt.entries) {
      // Answerable only if a clip synced AFTER this one failed. If the engine
      // died and never came back, nothing did — and nobody is blamed.
      if (delivered <= entry.value) continue;
      blamed = true;
      if (ClipQueue.noteItemFailure(entry.key)) {
        await ClipQueue.parkFile(entry.key);
      }
    }
    if (blamed) {
      // The engine works; these clips are simply bad. Their requeue re-fires the
      // queue watcher, so a brief hold keeps that from becoming a spin — but
      // there is nothing to escalate away from, and escalating would delay the
      // good clips that are syncing perfectly well.
      ClipQueue.noteDrainFailure(escalate: false);
    } else {
      // Nothing was delivered after any failure: treat the engine as down and
      // back off properly. This is the case that must never blame a clip.
      ClipQueue.noteDrainFailure();
    }
  }
}
