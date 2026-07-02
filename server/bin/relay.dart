import 'dart:io';

import 'package:clippy_relay/relay.dart';

Future<void> main() async {
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await startServer(port);
  stdout.writeln('clippy-relay listening on :${server.port}');
}
