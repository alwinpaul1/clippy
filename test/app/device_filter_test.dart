import 'package:clippy/app/device_filter.dart';
import 'package:clippy/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final devices = [
    for (var i = 0; i < 20; i++) (name: 'Device $i', count: i + 1),
  ];

  Future<List<String?>> pump(WidgetTester t, {String? value}) async {
    final picks = <String?>[];
    await t.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Scaffold(
        body: DeviceFilterButton(
          devices: devices,
          value: value,
          thisDevice: 'Device 3',
          onChanged: picks.add,
        ),
      ),
    ));
    return picks;
  }

  testWidgets('one button for any number of devices', (t) async {
    await pump(t);
    expect(find.text('All devices'), findsOneWidget);
    expect(find.text('Device 0'), findsNothing);
  });

  testWidgets('picking a device from the sheet', (t) async {
    final picks = await pump(t);
    await t.tap(find.text('All devices'));
    await t.pumpAndSettle();
    expect(find.text('Show clips from'), findsOneWidget);
    expect(find.text('This device · 4 clips'), findsOneWidget);
    // 20 devices: the sheet offers a filter field.
    await t.enterText(find.byType(TextField), 'device 1');
    await t.pumpAndSettle();
    expect(find.text('Device 2'), findsNothing);
    await t.tap(find.text('Device 12'));
    await t.pumpAndSettle();
    expect(picks, ['Device 12']);
    expect(find.text('Show clips from'), findsNothing);
  });

  testWidgets('dismissing the sheet changes nothing', (t) async {
    final picks = await pump(t, value: 'Device 5');
    await t.tap(find.text('Device 5'));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(10, 10)); // the barrier
    await t.pumpAndSettle();
    expect(picks, isEmpty);
  });

  testWidgets('a filtered view has a one-tap way back', (t) async {
    final picks = await pump(t, value: 'Device 5');
    await t.tap(find.byTooltip('Show all devices'));
    expect(picks, [null]);
  });
}
