// Dev tool: acts as a second Clippy device. Seals a clip with the same master
// key and sends it to the relay room, so we can verify cross-device sync from
// the command line. Usage: dart run tool/peer_send.dart "message"
import 'dart:convert';
import 'dart:io';

import 'package:clippy/core/pairing/pairing_key.dart';

const relay = 'wss://clippy-relay-production.up.railway.app';

Future<void> main(List<String> args) async {
  final message = args.isNotEmpty ? args.join(' ') : 'Hello from your Mac 👋';

  // Deterministic demo key (32 zero bytes) so its base64 payload has no URL-
  // unsafe characters and is trivial to type into the phone.
  final pk = PairingKey(List<int>.filled(32, 0));
  final crypto = await pk.cryptoBox();
  final room = await pk.roomToken();

  stdout.writeln('PAYLOAD=${pk.toQrPayload()}');
  stdout.writeln('ROOM=$room');

  final ws = await WebSocket.connect(relay);
  ws.add(jsonEncode({'type': 'join', 'room': room}));
  await Future<void>.delayed(const Duration(milliseconds: 400));

  final sealed = await crypto.seal(message, source: 'mac-peer');
  ws.add(jsonEncode({'type': 'clip', 'clip': sealed.toMap()}));
  stdout.writeln('SENT: "$message"');

  await Future<void>.delayed(const Duration(milliseconds: 800));
  await ws.close();
}
