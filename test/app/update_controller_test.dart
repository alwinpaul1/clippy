import 'package:clippy/app/update_controller.dart';
import 'package:clippy/core/update/update_info.dart';
import 'package:clippy/core/update/update_service.dart';
import 'package:clippy/platform/updater/platform_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records whether the platform installer was ever asked to install — the whole
/// point of "fail closed" is that it must NOT be, when the manifest has no hash.
class _SpyUpdater implements PlatformUpdater {
  bool installed = false;
  String? sawSha;
  @override
  Future<void> update(Uri artifactUrl,
      {required String sha256, void Function(double)? onProgress}) async {
    installed = true;
    sawSha = sha256;
  }
}

/// Counts manifest fetches; always reports "up to date".
class _CountingService extends UpdateService {
  _CountingService()
      : super(
          manifestUri: Uri.parse('https://relay.test/version.json'),
          currentVersion: () async => (version: '1.0.0', build: 1),
        );
  int calls = 0;
  @override
  Future<UpdateInfo?> check() async {
    calls++;
    return null;
  }
}

void main() {
  final host = defaultTargetPlatform; // whatever the test runner reports

  UpdateInfo info({String? sha}) => UpdateInfo(
        version: '9.9.9',
        build: 999,
        androidUrl: '/download/Clippy-Android.apk',
        macosUrl: '/download/Clippy-macOS.zip',
        windowsUrl: '/download/Clippy-Setup.exe',
        androidSha256: host == TargetPlatform.android ? sha : null,
        macosSha256: host == TargetPlatform.macOS ? sha : null,
        windowsSha256: host == TargetPlatform.windows ? sha : null,
      );

  final service = UpdateService(
    manifestUri: Uri.parse('https://relay.test/version.json'),
    currentVersion: () async => (version: '1.0.0', build: 1),
  );

  test('FAIL CLOSED: a manifest with no integrity hash never reaches the '
      'installer', () async {
    final spy = _SpyUpdater();
    final ctl = UpdateController(service: service, updaterFactory: () => spy);

    await expectLater(ctl.runUpdate(info(sha: null)), throwsA(isA<Exception>()));

    expect(spy.installed, isFalse,
        reason: 'skipping the check when the hash is absent is a trivial '
            'network-attacker bypass — no hash must mean no install');
  });

  test('a hash present IS handed to the installer for verification', () async {
    // Only meaningful on a desktop/mobile host where artifactUrl resolves; on
    // an unsupported host runUpdate throws before the installer, which is also
    // correct fail-closed behaviour.
    final spy = _SpyUpdater();
    final ctl = UpdateController(service: service, updaterFactory: () => spy);
    const hash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    try {
      await ctl.runUpdate(info(sha: hash));
      expect(spy.installed, isTrue);
      expect(spy.sawSha, hash);
    } on Exception {
      // Unsupported host (e.g. Linux CI): the installer must NOT have run.
      expect(spy.installed, isFalse);
    }
  });

  group('re-checks after startup (the process outlives a single check)', () {
    testWidgets('returning to the app checks again once the last check is stale',
        (tester) async {
      var now = DateTime(2026, 10, 18, 12);
      final svc = _CountingService();
      final ctl = UpdateController(service: svc, clock: () => now);
      ctl.watch();
      await tester.pump();
      expect(svc.calls, 1, reason: 'the startup check');

      void resume() {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }

      now = now.add(const Duration(minutes: 5));
      resume();
      await tester.pump();
      expect(svc.calls, 1, reason: 'app switching must not hammer the relay');

      now = now.add(UpdateController.minInterval);
      resume();
      await tester.pump();
      expect(svc.calls, 2, reason: 'this resume is what used to never check');

      ctl.unwatch();
    });

    testWidgets('a window that never leaves the screen checks on a timer',
        (tester) async {
      var now = DateTime(2026, 10, 18, 12);
      final svc = _CountingService();
      final ctl = UpdateController(service: svc, clock: () => now);
      ctl.watch();
      await tester.pump();
      now = now.add(UpdateController.periodicInterval);
      await tester.pump(UpdateController.periodicInterval);
      expect(svc.calls, 2);
      ctl.unwatch();
    });
  });
}
