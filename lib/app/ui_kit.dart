import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../platform/foreground_service.dart';
import 'theme.dart';

/// Small shared pieces of the 2026-10 redesign. Each one exists because two or
/// more screens draw it; a one-off stays in its screen.

/// A 40px round icon button on the card tone: the header and toolbar action.
/// Round and filled so it reads as a control on the bare paper canvas, where
/// a naked glyph floats.
class RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final Color? fill;
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fill ?? c.surface,
        shape: CircleBorder(
          side: c.isDark ? BorderSide(color: c.border) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 19, color: color ?? c.ink),
          ),
        ),
      ),
    );
  }
}

/// The sync light as a pill: dot + one honest sentence. Green when the UI's
/// connection AND background sync are alive, red otherwise. A green dot used
/// to mean only "the UI's own socket is up" and stayed green through a
/// six-hour background outage; it reports both now.
class SyncStatusPill extends StatelessWidget {
  final bool connected;
  final int deviceCount;
  const SyncStatusPill({
    super.key,
    required this.connected,
    required this.deviceCount,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return ValueListenableBuilder<bool>(
      valueListenable: ForegroundServiceManager.backgroundSyncAlive,
      builder: (context, bgAlive, _) {
        final warn = !connected || !bgAlive;
        final label = !connected
            ? 'Reconnecting…'
            : !bgAlive
                // The app is open, so "open Clippy" would be an instruction
                // the user cannot follow. Say what is true; the health watch
                // is already retrying.
                ? 'Background sync stopped, retrying'
                : deviceCount > 1
                    ? 'Synced · $deviceCount devices'
                    : 'Synced';
        final tone = warn ? c.rust : c.syncOk;
        return Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: c.isDark ? 0.14 : 0.09),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: Ct.body(12.5, weight: FontWeight.w600, color: tone),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A horizontal pill toggle: the home filter (All / Text / Links / Images)
/// and the add-device QR / Key switch. Selected = ink fill, the rest are bare
/// labels, so the choice reads at a glance without colour.
class PillSegments<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool expand;
  const PillSegments({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final pills = [
      for (final (v, label) in options)
        _wrap(
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: v == value ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                style: Ct.body(
                  13,
                  weight: FontWeight.w600,
                  color: v == value ? scheme.onPrimary : c.muted2,
                ),
              ),
            ),
          ),
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, children: pills),
    );
  }

  Widget _wrap(Widget w) => expand ? Expanded(child: w) : w;
}

/// The small tracked label above a group ("TODAY", "THIS DEVICE").
class SectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  const SectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(4, 18, 4, 8),
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Text(text.toUpperCase(), style: Ct.meta(color: context.ck.muted)),
      );
}

/// The one confirm dialog for destructive actions: title, one sentence, a
/// quiet Cancel and a red action. Returns true when confirmed.
Future<bool?> confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) {
  final c = context.ck;
  return showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (context) => Dialog(
      backgroundColor: c.dialogBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Ct.title(20, color: c.ink)),
            const SizedBox(height: 8),
            Text(body, style: Ct.body(14, color: c.muted2, height: 1.5)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Cancel',
                      style: Ct.body(14, weight: FontWeight.w600, color: c.ink)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(action),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Relative age for meta lines: "now", "4 min", "2 h", then a clock time.
String relativeAge(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return '${d.inHours} h';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Back button + title, for pushed pages. macOS gets extra top room so the
/// back button clears the traffic lights (the title bar is transparent).
class PageHeader extends StatelessWidget {
  final String title;
  const PageHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, defaultTargetPlatform == TargetPlatform.macOS ? 30 : 10, 20, 10),
      child: Row(
        children: [
          RoundIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 14),
          Text(title, style: Ct.title(22, color: c.ink)),
        ],
      ),
    );
  }
}

/// A grouped list: one card, hairline dividers between rows (inset past the
/// rows' leading marks).
class GroupCard extends StatelessWidget {
  final List<Widget> children;
  final double dividerIndent;
  const GroupCard({super.key, required this.children, this.dividerIndent = 62});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return ClipCard(
      radius: 20,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(height: 1, thickness: 1, indent: dividerIndent, color: c.border),
            children[i],
          ],
        ],
      ),
    );
  }
}
