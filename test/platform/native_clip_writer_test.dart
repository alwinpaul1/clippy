import 'dart:typed_data';

import 'package:clippy/platform/flutter_clipboard_writer.dart';
import 'package:clippy/platform/image_clipboard.dart';
import 'package:clippy/platform/native_clip_writer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('clippy/clipwrite');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void nativeAnswers(Object? answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer;
    });
  }

  setUp(() {
    calls = [];
    NativeClipWriter.debugIsAndroid = true;
  });

  tearDown(() {
    NativeClipWriter.debugIsAndroid = null;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('writeText sends the text and reports the native result', () async {
    nativeAnswers(true);
    expect(await NativeClipWriter.writeText('hello'), isTrue);
    expect(calls.single.method, 'writeText');
    expect(calls.single.arguments, {'text': 'hello'});
  });

  test('no handler on this engine -> false, so the caller falls back', () async {
    // No mock registered: invokeMethod throws MissingPluginException.
    expect(await NativeClipWriter.writeText('hello'), isFalse);
  });

  test('off Android it never touches the channel', () async {
    NativeClipWriter.debugIsAndroid = false;
    nativeAnswers(true);
    expect(await NativeClipWriter.writeText('hello'), isFalse);
    expect(calls, isEmpty);
  });

  test('ImageClipboard.write hands the bytes to the native writer with their '
      'own extension (no re-encode)', () async {
    nativeAnswers(true);
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
    await ImageClipboard.write(jpeg);
    expect(calls.single.method, 'writeImage');
    expect(calls.single.arguments['ext'], 'jpg');
    expect(calls.single.arguments['bytes'], jpeg);
  });

  group('FlutterClipboardWriter', () {
    late List<MethodCall> platformCalls;
    setUp(() {
      platformCalls = [];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
    });

    test('uses the native writer when it succeeds', () async {
      nativeAnswers(true);
      await const FlutterClipboardWriter().setText('x');
      expect(calls.single.method, 'writeText');
      expect(platformCalls.where((c) => c.method == 'Clipboard.setData'), isEmpty);
    });

    test('falls back to Clipboard.setData when the native write fails', () async {
      nativeAnswers(false);
      await const FlutterClipboardWriter().setText('x');
      expect(platformCalls.where((c) => c.method == 'Clipboard.setData'), hasLength(1));
    });
  });
}
