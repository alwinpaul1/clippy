import 'package:clippy/app/pairing_page.dart';
import 'package:clippy/core/pairing/pairing_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('generate then pair yields a 32-byte key', (tester) async {
    PairingKey? captured;
    await tester.pumpWidget(MaterialApp(
      home: PairingPage(onPaired: (k) async => captured = k),
    ));

    await tester.tap(find.text('Generate a new key'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isNotEmpty);

    // The QR pushes the button below the fold in the test viewport; scroll to it.
    await tester.ensureVisible(find.text('Pair this device'));
    await tester.pump();
    await tester.tap(find.text('Pair this device'));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.masterKey.length, 32);
  });

  testWidgets('an invalid key does not pair', (tester) async {
    var called = false;
    await tester.pumpWidget(MaterialApp(
      home: PairingPage(onPaired: (k) async => called = true),
    ));

    await tester.enterText(find.byType(TextField), 'not!!a!!valid!!key');
    await tester.ensureVisible(find.text('Pair this device'));
    await tester.pump();
    await tester.tap(find.text('Pair this device'));
    await tester.pump();

    expect(called, isFalse);
  });
}
