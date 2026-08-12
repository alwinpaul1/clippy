import 'package:clippy/platform/share_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contract of the clippy/share `bgSyncStatus` call, now that background sync
/// stands on THREE grants (accessibility, overlay, battery exemption). The
/// battery flag is what the Pixel/Lenovo report turned on: it governs whether
/// the relay connection survives Doze and whether Android 12+ lets the service
/// restart from the background — and it must never be presumed granted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('clippy/share');
  Map<String, Object>? reply;

  setUp(() {
    reply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'bgSyncStatus') return reply;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('parses all three grants', () async {
    reply = {'enabled': true, 'overlay': true, 'battery': true};

    final s = await ShareChannel.bgSyncStatus();

    expect(s.enabled, isTrue);
    expect(s.overlay, isTrue);
    expect(s.battery, isTrue);
  });

  test('a native side without the battery key means NOT exempt', () async {
    reply = {'enabled': true, 'overlay': true};

    final s = await ShareChannel.bgSyncStatus();

    expect(s.battery, isFalse,
        reason: 'unknown must read as missing — "granted by default" is how '
            'the exemption stayed invisible in the first place');
  });

  test('a dead channel reads as nothing granted', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null); // desktop / no native side

    final s = await ShareChannel.bgSyncStatus();

    expect((s.enabled, s.overlay, s.battery), (false, false, false));
  });
}
