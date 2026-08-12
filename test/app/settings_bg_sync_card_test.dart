import 'package:clippy/app/settings_page.dart';
import 'package:clippy/app/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The report behind these tests: "we turned on whatever Clippy's settings
/// told us and background sync still doesn't work" (Pixel 9 Pro + Lenovo tab).
/// The Settings screen listed two steps — accessibility + overlay — while the
/// third thing background sync actually stands on, the battery-optimisation
/// exemption, was asked for in a single system dialog at first launch and
/// never surfaced again. So "did everything the app asked" genuinely wasn't
/// enough: Doze cut the relay connection minutes after the screen locked, and
/// Android 12+ refused background restarts after an OEM kill.
///
/// These tests pin the fix: the battery step is PART OF THE SETTINGS FLOW —
/// visible when missing, green when granted, and one tap away from the system
/// dialog.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const share = MethodChannel('clippy/share');
  late List<String> calls;
  late Map<String, Object> status;

  setUp(() {
    calls = [];
    status = {'enabled': true, 'overlay': true, 'battery': false};
    PackageInfo.setMockInitialValues(
      appName: 'clippy',
      packageName: 'dev.alwin.clippy',
      version: '0.0.0',
      buildNumber: '0',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(share, (call) async {
      calls.add(call.method);
      if (call.method == 'bgSyncStatus') return status;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(share, null);
  });

  // The background-sync card only renders on Android; the variant sets (and
  // correctly restores) debugDefaultTargetPlatformOverride around each test.
  final onAndroid = TargetPlatformVariant.only(TargetPlatform.android);

  Future<void> pumpSettings(WidgetTester tester) async {
    // Tall surface so the whole background-sync card is laid out (ListView
    // builds lazily; a short viewport would hide the rows under test).
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        theme: ThemeController(),
        onAddDevice: () {},
        onUnpair: () async {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'a missing battery exemption is a VISIBLE step 3, and tapping it '
      'requests the exemption', (tester) async {
    await pumpSettings(tester);

    // All three steps are on screen — a user following the list cannot stop
    // at two and still believe they did everything.
    //
    // The label carries no "3." any more: the card redesign moved the step
    // number into the leading badge, so the number is asserted separately
    // below. Do NOT "restore" the number to the label — it would then render
    // twice, once in the badge and once in the text.
    expect(find.text('Accessibility enabled'), findsOneWidget);
    expect(find.text('Overlay allowed'), findsOneWidget);
    expect(find.text('Allow background battery use'), findsOneWidget);
    // The step is still numbered 3, and that number is what tells the user
    // the sequence has three parts rather than two.
    expect(find.text('3'), findsOneWidget,
        reason: 'the badge must number this step, or the list reads as two '
            'steps plus an afterthought');

    await tester.tap(find.text('Allow background battery use'));
    await tester.pump();

    expect(calls, contains('requestBatteryExemption'),
        reason: 'the row must lead straight to the system dialog — a step '
            'the user cannot act on is not a step');
  }, variant: onAndroid);

  testWidgets('a granted exemption shows as done, like the other two steps',
      (tester) async {
    status = {'enabled': true, 'overlay': true, 'battery': true};

    await pumpSettings(tester);

    expect(find.text('Background use allowed'), findsOneWidget);
    expect(find.text('Allow background battery use'), findsNothing);
  }, variant: onAndroid);

  testWidgets(
      'an old native side that reports no battery key reads as NOT granted '
      '(never silently green)', (tester) async {
    status = {'enabled': true, 'overlay': true}; // pre-battery native build

    await pumpSettings(tester);

    expect(find.text('Allow background battery use'), findsOneWidget,
        reason: 'defaulting an unknown exemption to "granted" would repaint '
            'the exact lie this screen used to tell');
  }, variant: onAndroid);
}
