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
  for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    sig.watch().listen((_) async {
      await repo.flush();
      exit(0);
    });
  }
}
