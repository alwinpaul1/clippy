import 'package:clippy/app/theme.dart';
import 'package:clippy/app/update_card.dart';
import 'package:clippy/app/update_controller.dart';
import 'package:clippy/app/update_sheet.dart';
import 'package:clippy/core/update/update_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const info = UpdateInfo(version: '9.9.9', build: 999, features: ['x']);

  Widget app(Widget home) {
    final key = GlobalKey<NavigatorState>();
    return MaterialApp(
      theme: lightTheme,
      navigatorKey: key,
      builder: (context, child) => UpdateCardHost(navigatorKey: key, child: child!),
      home: home,
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    updater.available.value = null;
    updateSheetOpen.value = false;
  });

  testWidgets('the card shows on ANY screen, not only home', (t) async {
    await t.pumpWidget(app(const Scaffold(body: Text('some other page'))));
    expect(find.text('Update available'), findsNothing);

    updater.available.value = info;
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('Clippy 9.9.9 is ready. Your clips and pairing stay as they are.'),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);
  });

  testWidgets("'See what's new' opens the changelog sheet", (t) async {
    await t.pumpWidget(app(const Scaffold()));
    updater.available.value = info;
    await t.pumpAndSettle();
    await t.tap(find.text("See what's new"));
    await t.pumpAndSettle();
    expect(find.text('New in 9.9.9'), findsOneWidget);
    // Only the sheet: the card hides behind it, and comes back on close.
    expect(find.text('Update available'), findsNothing);
    Navigator.of(t.element(find.text('New in 9.9.9'))).pop();
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
  });

  testWidgets('dismissing remembers the version', (t) async {
    await t.pumpWidget(app(const Scaffold()));
    updater.available.value = info;
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel('Dismiss update'));
    await t.pumpAndSettle();
    expect(updater.available.value, isNull);
    expect(find.text('Update available'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('clippy.update.dismissed'), '9.9.9+999');
  });
}
