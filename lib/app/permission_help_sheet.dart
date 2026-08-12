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
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetGrabber(),
            Row(
              children: [
                GlyphPlate(
                  icon: Icons.shield_rounded,
                  base: Theme.of(context).colorScheme.primary,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: Ct.title(20, color: c.ink))),
              ],
            ),
            const SizedBox(height: 12),
            // The explainer scrolls; the two buttons stay pinned. `whatFor` is
            // caller-supplied and the steps are long, so on a short screen this
            // Column used to overflow rather than scroll — the sheet was built
            // as a fixed min-height Column and had no give at all.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(whatFor, style: Ct.body(14, color: c.muted2)),
                    const SizedBox(height: 16),
                    ClipCard(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Android guards this for apps installed outside the '
                            'Play Store, so you may see "App was denied access". '
                            'Here\'s how to get past it:',
                            style: Ct.body(13.5, color: c.ink),
                          ),
                          const SizedBox(height: 14),
                          _Step(
                              1,
                              'Tap "Open Settings" below and try to turn '
                              "Clippy's toggle on.",
                              c),
                          _Step(
                              2,
                              'If you see the "restricted setting" warning, open '
                              "Clippy's App info, tap the ⋮ menu (top-right), "
                              'then "Allow restricted settings" and confirm with '
                              'your PIN.',
                              c),
                          _Step(
                              3,
                              "Come back and turn the toggle on — it'll stick.",
                              c,
                              last: true),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              // No local style: the filled-button theme already carries the
              // brand fill and its matching foreground for BOTH themes, and
              // dark uses primaryFillDark rather than primary so white ink
              // clears 4.5:1 on it. Restating it here is how those two drift.
              child: FilledButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await onOpenSettings();
                },
                child: const Text('Open Settings'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  // borderStrong (M3 `outline`): an OutlinedButton's edge IS
                  // the button, so it must clear 3:1 (WCAG 1.4.11).
                  side: BorderSide(color: c.borderStrong),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
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

/// One step on a connected rail: the numbered badge, and — until the last
/// step — a thin line running down to the next badge. The line is what makes
/// three sentences read as ONE procedure with an order, not three tips.
class _Step extends StatelessWidget {
  final int n;
  final String text;
  final ClippyColors c;
  final bool last;
  const _Step(this.n, this.text, this.c, {this.last = false});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: c.isDark ? 0.24 : 0.12),
                  shape: BoxShape.circle,
                ),
                child: Text('$n',
                    style:
                        Ct.body(11, weight: FontWeight.w700, color: c.accent)),
              ),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    decoration: BoxDecoration(
                      color: c.accent.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 14),
              child: Text(text, style: Ct.body(13.5, color: c.ink)),
            ),
          ),
        ],
      ),
    );
  }
}
