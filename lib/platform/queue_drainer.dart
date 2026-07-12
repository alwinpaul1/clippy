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
    // EVERY clip this run has already handled — delivered or failed. Failures
    // stay on disk and must be stepped over; a success is normally gone, but if
    // drain()'s delete ever fails (read-only mount, a hostile OEM FS) the file
    // comes back, and without this the same clip would be re-delivered on every
    // iteration forever. This set is what makes the loop finite.
    final seen = <String>{};
    var deliveredTotal = 0;
    var hadFailure = false;
    var i = 0;
    var items = const <ClipQueueItem>[];
    try {
      await ClipQueue.beat();
      // drain() returns a bounded BATCH (a long-dead service leaves a huge
      // backlog, and reading it all at once would OOM the app at launch), so
      // keep going until nothing is left that this run has not already tried.
      while (canContinue()) {
        i = 0;
        items = const [];
        final seenBefore = seen.length;
        items = await ClipQueue.drain(skip: seen);
        if (items.isEmpty) break;

        // Judgement is scoped to THIS BATCH, whose clips were attempted
        // back-to-back. A run-global counter cannot tell "this clip is bad"
        // from "the engine was briefly broken and then recovered": with a
        // global counter, one delivery in a LATER batch — after a transient
        // fault heals — convicts every clip that failed before it.
        var deliveredInBatch = 0;
        final failedAt = <String, int>{};
        for (; i < items.length; i++) {
          if (!canContinue()) return; // finally puts items[i..] back
          final item = items[i];
          final name = item.name;
          try {
            await process(item);
            ClipQueue.clearFailures(name);
            deliveredInBatch++;
            deliveredTotal++;
          } catch (_) {
            // Straight back to disk: a clip is never the sole property of a
            // process that might be killed.
            await ClipQueue.requeue(item);
            if (name != null) {
              if (items.length == 1) {
                // ALONE in its batch — and it always will be, because drain()
                // gives an over-budget file a batch of its own. Same-batch
                // evidence can therefore never exist for it, so it could never
                // be blamed, never parked, and would re-read its 30MB from
                // flash on every drain forever. For a solo clip only, a
                // delivery LATER IN THE RUN is admissible: the clip is the one
                // thing that distinguishes its own failure (it is too big), and
                // a genuinely broken engine delivers nothing at all.
                _solo.add(_Solo(name, deliveredTotal));
              } else {
                failedAt.putIfAbsent(name, () => deliveredInBatch);
              }
            }
            hadFailure = true;
          }
          if (name != null) seen.add(name); // handled — never revisit this run
        }
        await _judgeBatch(failedAt, deliveredInBatch);

        // Termination guard: a batch that handled nothing new would be re-read
        // forever. Every item above enters `seen`, so this cannot happen — but
        // a spinning core is not a failure mode worth resting on an argument.
        if (seen.length == seenBefore) break;
      }
    } finally {
      beat.cancel();
      if (i < items.length) await ClipQueue.requeueAll(items.sublist(i));
      // Solo failures can only be judged now, when the run's full delivery
      // count is known.
      for (final s in _solo) {
        if (deliveredTotal <= s.deliveredBefore) continue; // engine never worked
        if (ClipQueue.noteItemFailure(s.name)) await ClipQueue.parkFile(s.name);
      }
      _solo.clear();

      if (hadFailure && deliveredTotal > 0) {
        // The engine PROVED itself this run, whatever we could or could not
        // pin on the clips that failed. A brief hold stops the requeue's
        // inotify event becoming a spin — but escalating would make every GOOD
        // clip wait up to four minutes because of a jam we cannot even convict,
        // and (since a run with failures never clears the backoff) it would
        // never heal.
        ClipQueue.noteDrainFailure(escalate: false);
      } else if (hadFailure) {
        // Failures and NOTHING delivered anywhere: the engine is down. Back off
        // properly. This is the case that must never blame anyone.
        ClipQueue.noteDrainFailure();
      } else if (deliveredTotal > 0) {
        // A clean, productive run. Only this clears the backoff — an empty
        // directory is not evidence (the other isolate may be mid-batch, with
        // its files already deleted).
        ClipQueue.noteDrainSuccess();
      }
      _draining = false;
    }
  }

  final List<_Solo> _solo = [];

  /// Judge ONE batch. A clip is answerable only if another clip synced AFTER it
  /// failed, IN THIS BATCH — the only evidence that the engine was working at
  /// the moment this clip was not. An engine that dies part-way (a disk filling
  /// up) delivers first and throws after, convicting nobody; an engine that
  /// recovers later in the run convicts nobody either, because its recovery
  /// lands in a different batch.
  Future<void> _judgeBatch(
      Map<String, int> failedAt, int deliveredInBatch) async {
    for (final entry in failedAt.entries) {
      if (deliveredInBatch <= entry.value) continue; // nothing synced after it
      if (ClipQueue.noteItemFailure(entry.key)) {
        await ClipQueue.parkFile(entry.key); // atomic rename; never deleted
      }
    }
  }
}

/// A clip that failed while ALONE in its batch — the only shape for which
/// same-batch evidence is impossible by construction (drain() gives an
/// over-budget file a batch to itself). [deliveredBefore] is the run's delivery
/// count at the moment it failed; anything delivered after that proves the
/// engine was working.
class _Solo {
  const _Solo(this.name, this.deliveredBefore);
  final String name;
  final int deliveredBefore;
}
