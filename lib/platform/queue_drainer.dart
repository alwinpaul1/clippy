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
    // either deleted it. The flag MUST be set before the first await: the
    // watcher and the service's 10s tick both call this, and an await here let
    // both pass the check and drain concurrently — the exact double-upload this
    // guard exists to prevent.
    if (_draining || !canContinue()) return;
    _draining = true;
    try {
      // A cooldown holds us off a broken engine, or off a jam we keep
      // re-reading. It must NEVER make the user's next copy wait behind that —
      // but nor may a fresh copy become a licence to drag the whole known-bad
      // backlog back through a sick disk. So under a hold we run, but ONLY over
      // clips we have never failed on.
      final holding = ClipQueue.inCooldown;
      if (holding && !await ClipQueue.hasUntriedWork()) return;
      await _drain(holding);
    } finally {
      _draining = false;
    }
  }

  Future<void> _drain(bool holding) async {
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
    // Under a hold, every clip we have already failed on is off-limits: they are
    // precisely what the hold is holding off.
    final seen = holding ? {...ClipQueue.triedNames} : <String>{};
    // Over-budget clips that failed. They are structurally alone in their batch,
    // so same-batch evidence cannot exist for them; they are judged at the end
    // of the run instead. A LOCAL, never a field: as a field, two overlapping
    // runs would judge and clear each other's entries.
    final solo = <_Solo>[];
    var deliveredTotal = 0;
    var hadFailure = false;
    // Event order, so the ENGINE can be judged by the same rule as the clips:
    // evidence must come AFTER the failure. A dying engine (a disk filling up)
    // delivers first and throws after — "something was delivered" cannot see
    // that, and would hold off for a flat 15s while re-reading and re-writing
    // the whole backlog against a full disk every 20 seconds.
    var events = 0;
    var lastDelivery = -1;
    var lastFailure = -1;
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
            lastDelivery = events++;
          } catch (_) {
            // Straight back to disk: a clip is never the sole property of a
            // process that might be killed.
            await ClipQueue.requeue(item);
            // Did the LINK die? store.append() throws when the socket is
            // half-open, and canContinue() reads that same socket. The clip is
            // innocent — it never got a fair attempt. Blaming it here would
            // strike it out and, after three badly-timed disconnects (a flaky
            // link is the condition this app exists for), PARK a perfectly good
            // clip. Abort instead: no strike, no "tried" mark, no backoff.
            if (!canContinue()) {
              i++; // already back on disk — the finally must not requeue it too
              return;
            }
            lastFailure = events++;
            ClipQueue.noteAttemptFailed(name); // tried — so the hold applies
            if (name != null) {
              // Solo BECAUSE IT IS OVERSIZED — not merely because the queue
              // happened to hold one file. drain() gives an over-budget file a
              // batch of its own, so same-batch evidence can never exist for it;
              // for anything else, a batch of one is an accident of timing and
              // must not lower the standard of proof.
              final bytes =
                  item.imageBytes?.length ?? item.text?.length ?? 0;
              if (bytes >= ClipQueue.maxDrainBytes) {
                // For an over-budget clip ONLY, a delivery later in the run is
                // admissible evidence: it is the one thing that distinguishes
                // its own failure (it is too big to encode), and an engine that
                // is genuinely broken delivers nothing at all. Without this it
                // could never be parked and would re-read its bulk from flash
                // on every drain, forever.
                solo.add(_Solo(name, deliveredTotal));
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
      for (final s in solo) {
        if (deliveredTotal <= s.deliveredBefore) continue; // engine never worked
        if (ClipQueue.noteItemFailure(s.name)) await ClipQueue.parkFile(s.name);
      }

      if (hadFailure && lastDelivery > lastFailure) {
        // A clip synced AFTER the last failure: the engine is working NOW, and
        // what failed is the queue's problem, not its. A brief hold stops the
        // requeue's inotify event becoming a spin — but escalating would make
        // good clips wait minutes for a jam that is not the engine's fault.
        ClipQueue.noteDrainFailure(escalate: false);
      } else if (hadFailure) {
        // The last thing that happened was a FAILURE — the engine is down, or
        // dying (it delivered, then the disk filled). Back off properly:
        // re-reading and re-writing the whole backlog every 20s against a full
        // disk is how a "rare" requeue-write loss stops being rare.
        ClipQueue.noteDrainFailure();
      } else if (deliveredTotal > 0 && !holding) {
        // A clean, productive run that looked at EVERYTHING. Only this clears
        // the backoff.
        //
        // Not a holding run: it deliberately skipped every clip we have failed
        // on, so it proves nothing about them. Clearing the hold on its say-so
        // would let the very next run re-read the whole known-bad backlog —
        // which is what the hold is for. It expires on its own schedule, and
        // the backlog is retried then.
        //
        // And not an empty directory: that is not evidence either (the other
        // isolate may be mid-batch, with its files already deleted).
        ClipQueue.noteDrainSuccess();
      }
    }
  }

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
