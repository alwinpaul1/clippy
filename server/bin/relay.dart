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
}
