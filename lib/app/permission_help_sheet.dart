import 'package:flutter/material.dart';

import '../platform/share_channel.dart';
import 'theme.dart';

/// Pre-flight explainer for the Android "restricted setting" gate.
///
/// Since Android 13, apps installed outside the Play Store (Clippy is a
/// sideloaded APK) have their Accessibility and display-over-apps toggles
/// blocked behind an "App was denied access" dialog. There is no way for an app
/// to bypass it — the user must open App info → ⋮ → "Allow restricted settings"
/// once. This sheet walks them through that instead of dropping them cold into
/// Settings where the flow dead-ends. Text-only steps so it holds across
/// phone brands.
Future<void> showPermissionHelpSheet(
  BuildContext context, {
  required String title,
  required String whatFor,
  required Future<void> Function() onOpenSettings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.ck.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PermissionHelpSheet(
      title: title,
      whatFor: whatFor,
      onOpenSettings: onOpenSettings,
    ),
  );
}

class _PermissionHelpSheet extends StatelessWidget {
  final String title;
  final String whatFor;
  final Future<void> Function() onOpenSettings;
  const _PermissionHelpSheet({
    required this.title,
    required this.whatFor,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: c.green, size: 24),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: Ct.title(22, color: c.ink))),
              ],
            ),
            const SizedBox(height: 8),
            Text(whatFor, style: Ct.body(14, color: c.muted, height: 1.4)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Android guards this for apps installed outside the Play '
                    'Store, so you may see "App was denied access". Here\'s how '
                    'to get past it:',
                    style: Ct.body(13.5, color: c.ink, height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  _Step(1, 'Tap "Open Settings" below and try to turn Clippy\'s '
                      'toggle on.', c),
                  _Step(2, 'If you see the "restricted setting" warning, open '
                      'Clippy\'s App info, tap the ⋮ menu (top-right), then '
                      '"Allow restricted settings" and confirm with your PIN.', c),
                  _Step(3, 'Come back and turn the toggle on — it\'ll stick.', c,
                      last: true),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: c.green,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await onOpenSettings();
                },
                child: Text('Open Settings',
                    style: Ct.body(15, weight: FontWeight.w600, color: Ck.bg)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: c.borderStrong),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await ShareChannel.openAppInfo();
                },
                child: Text('Open Clippy App info',
                    style: Ct.body(15, weight: FontWeight.w600, color: c.ink)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String text;
  final ClippyColors c;
  final bool last;
  const _Step(this.n, this.text, this.c, {this.last = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.green.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Text('$n',
                style: Ct.body(11, weight: FontWeight.w700, color: c.green)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Ct.body(13.5, color: c.ink, height: 1.45)),
          ),
        ],
      ),
    );
  }
}
