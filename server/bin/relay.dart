import 'dart:io';

import 'package:clippy_relay/relay.dart';

Future<void> main() async {
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final dbPath = Platform.environment['DB_PATH'];
  final repo = (dbPath != null && dbPath.isNotEmpty)
      ? FileClipRepository(dbPath)
      : InMemoryClipRepository();

  final server = await startServer(port, repo: repo);
  stdout.writeln('clippy-relay listening on :${server.port} '
      '(history: ${dbPath ?? "in-memory"})');

  // Railway SIGTERMs the container on every deploy. Without this flush,
  // anything inside the persist debounce dies with the process: adds the
  // sender was already acked for are lost, and deletes/clears the user was
  // told are "gone for good" resurrect from the stale file.
  //
  // Order matters: STOP ACCEPTING first — the server would otherwise keep
  // storing and ACKING clips while the flush's write is in flight, and a
  // clip acked after the snapshot was taken would die with the process (its
  // sender already discarded the resend copy on the ack). Guarded so a
  // second signal can't interleave, and exit lives in a finally with a
  // timeout on the flush so a hung volume can never leave the process
  // ignoring SIGTERM (watch() disables the default handler).
  var exiting = false;
  Future<void> shutdown() async {
    if (exiting) return;
    exiting = true;
    try {
      await server.close(force: true);
      await repo.flush().timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best effort — never block the exit.
    } finally {
      exit(0);
    }
  }

  for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    sig.watch().listen((_) => shutdown());
  }
}
