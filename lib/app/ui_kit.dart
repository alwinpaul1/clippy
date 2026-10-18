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

/// Motion for controls (beUI motion guides): a filter is a FREQUENT action,
/// so everything stays well under 300ms. The indicator is a surface already
/// on screen moving between positions, so it eases in and out; a press is
/// immediate feedback.
abstract class ClipMotion {
  static const slide = Duration(milliseconds: 220);
  static const slideCurve = Curves.easeInOutCubic;
  static const press = Duration(milliseconds: 120);
}

/// A horizontal pill toggle: the home filter (All / Text / Links / Images)
/// and the add-device QR / Key switch. Selected = ink fill, the rest are bare
/// labels, so the choice reads at a glance without colour.
///
/// ONE ink indicator slides from the old choice to the new one (layout
/// continuity: the same surface travels, it is not a fade-out here and a
/// fade-in there), and each label turns on-ink exactly where the moving ink
/// covers it. With reduced motion the indicator jumps; the state change is
/// still instant and obvious, just without travel.
class PillSegments<T> extends StatefulWidget {
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
  State<PillSegments<T>> createState() => _PillSegmentsState<T>();
}

class _PillSegmentsState<T> extends State<PillSegments<T>> {
  final _stack = GlobalKey();
  late List<GlobalKey> _keys = _newKeys();
  Rect? _rect; // the selected pill, in the stack's coordinates
  T? _pressed;

  List<GlobalKey> _newKeys() => [for (final _ in widget.options) GlobalKey()];

  @override
  void didUpdateWidget(PillSegments<T> old) {
    super.didUpdateWidget(old);
    if (old.options.length != widget.options.length) _keys = _newKeys();
  }

  /// Measure the selected pill after layout; rebuild only when it moved.
  void _measure() {
    final i = widget.options.indexWhere((o) => o.$1 == widget.value);
    final stack = _stack.currentContext?.findRenderObject();
    final pill = i < 0 ? null : _keys[i].currentContext?.findRenderObject();
    if (stack is! RenderBox || pill is! RenderBox || !pill.hasSize) return;
    final r = pill.localToGlobal(Offset.zero, ancestor: stack) & pill.size;
    if (r != _rect && mounted) setState(() => _rect = r);
  }

  Widget _labels(Color Function(T v) color, {bool interactive = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final (i, (v, label)) in widget.options.indexed)
          _wrap(_pill(i, v, label, color(v), interactive, scheme)),
      ],
    );
  }

  Widget _pill(int i, T v, String label, Color fg, bool interactive, ColorScheme scheme) {
    final text = Center(
      widthFactor: widget.expand ? null : 1,
      heightFactor: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(label, style: Ct.body(13, weight: FontWeight.w600, color: fg)),
      ),
    );
    if (!interactive) return text;
    return Semantics(
      button: true,
      selected: v == widget.value,
      child: GestureDetector(
        key: _keys[i],
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = v),
        onTapCancel: () => setState(() => _pressed = null),
        onTap: () {
          setState(() => _pressed = null);
          widget.onChanged(v);
        },
        // Press feedback is a quick tint, not a scale: the label is drawn
        // twice (see build), and both copies must stay in register.
        child: AnimatedContainer(
          duration: ClipMotion.press,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: _pressed == v && v != widget.value
                ? scheme.surfaceContainerHigh
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: text,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.of(context).disableAnimations;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

    final r = _rect;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
      ),
      // Painted in order, no z-index: the ink indicator, the muted labels
      // (which take the taps), then the same labels in the on-ink colour,
      // clipped to wherever the indicator is right now. So every label is
      // exactly as readable mid-slide as at rest: white where the ink
      // covers it, grey where it does not.
      child: Stack(
        key: _stack,
        children: [
          if (r != null)
            Positioned.fill(
              child: TweenAnimationBuilder<Rect?>(
                tween: RectTween(end: r),
                duration: reduce ? Duration.zero : ClipMotion.slide,
                curve: ClipMotion.slideCurve,
                builder: (context, rect, _) => CustomPaint(
                  painter: _IndicatorPainter(rect ?? r, scheme.primary),
                ),
              ),
            ),
          _labels((_) => c.muted2, interactive: true),
          if (r != null)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: TweenAnimationBuilder<Rect?>(
                    tween: RectTween(end: r),
                    duration: reduce ? Duration.zero : ClipMotion.slide,
                    curve: ClipMotion.slideCurve,
                    builder: (context, rect, child) => ClipPath(
                      clipper: _PillClip(rect ?? r),
                      child: child,
                    ),
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      child: _labels((_) => scheme.onPrimary),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _wrap(Widget w) => widget.expand ? Expanded(child: w) : w;
}

class _IndicatorPainter extends CustomPainter {
  final Rect rect;
  final Color color;
  _IndicatorPainter(this.rect, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_IndicatorPainter old) => old.rect != rect || old.color != color;
}

class _PillClip extends CustomClipper<Path> {
  final Rect rect;
  _PillClip(this.rect);

  @override
  Path getClip(Size size) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)));

  @override
  bool shouldReclip(_PillClip old) => old.rect != rect;
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

/// Relative age for meta lines: "now", "4 min", "2 h", then "Yesterday", a
/// weekday within the week, and a date after that. A bare clock time on an
/// old clip (a pinned one from last month) read as "today at 4:04 PM".
String relativeAge(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return '${d.inHours} h';
  final days = DateTime(n.year, n.month, n.day)
      .difference(DateTime(t.year, t.month, t.day))
      .inDays;
  if (days <= 1) return 'Yesterday';
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  if (days < 7) return wd[t.weekday - 1];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = '${mo[t.month - 1]} ${t.day}';
  return t.year == n.year ? date : '$date, ${t.year}';
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
