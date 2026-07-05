import 'package:clippy/app/permission_help_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the restricted-settings steps and runs onOpenSettings',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showPermissionHelpSheet(
                context,
                title: 'Enable background sync',
                whatFor: 'reason',
                onOpenSettings: () async {
                  opened = true;
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The explainer surfaces the title, the ⋮ gate step, and both buttons.
    expect(find.text('Enable background sync'), findsOneWidget);
    expect(find.textContaining('Allow restricted settings'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Open Clippy App info'), findsOneWidget);

    // The primary button closes the sheet and runs the provided opener.
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });
}
