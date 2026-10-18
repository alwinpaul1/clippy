import 'package:flutter/material.dart';

import '../core/update/update_info.dart';
import '../platform/updater/platform_updater.dart' show IntegrityException;
import 'theme.dart';
import 'update_controller.dart';
import 'update_sheet.dart';

/// The update notice: a floating card above EVERY screen, modelled on the
/// Code UI / Orca desktop card. Bottom-right and 360 wide on a wide window,
/// full width with 16px gutters on a phone. It slides in from the right.
///
/// It replaced a banner in the home screen's bottom slot, which lost to two
/// warning banners on Android and did not exist on any other screen, so an
/// update could be out for days with nothing on screen saying so.
///
/// Mounted from `MaterialApp.builder`, i.e. ABOVE the Navigator: no Overlay
/// (so no Tooltip) and no Scaffold here. The release-notes sheet opens
/// through [navigatorKey].
class UpdateCardHost extends StatelessWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const UpdateCardHost({super.key, required this.child, required this.navigatorKey});

  /// Height the card covers at the bottom of a NARROW screen, so the home
  /// screen can lift its own bottom banner above it. 0 when hidden or wide.
  static final occupied = ValueNotifier<double>(0);

  static const wideBreakpoint = 480.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        ValueListenableBuilder<UpdateInfo?>(
          valueListenable: updater.available,
          builder: (context, info, _) {
            if (info == null) {
              _setOccupied(0);
              return const SizedBox.shrink();
            }
            final media = MediaQuery.of(context);
            final wide = media.size.width >= wideBreakpoint;
            return Positioned(
              right: 16,
              left: wide ? null : 16,
              bottom: 16 + media.padding.bottom,
              width: wide ? 360 : null,
              child: _Measured(
                onHeight: (h) => _setOccupied(wide ? 0 : h + 16),
                child: _UpdateCard(
                  key: ValueKey('${info.version}+${info.build}'),
                  info: info,
                  navigatorKey: navigatorKey,
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  static void _setOccupied(double v) {
    if (occupied.value == v) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => occupied.value = v);
  }
}

class _Measured extends StatefulWidget {
  final Widget child;
  final ValueChanged<double> onHeight;
  const _Measured({required this.child, required this.onHeight});
  @override
  State<_Measured> createState() => _MeasuredState();
}

class _MeasuredState extends State<_Measured> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = context.findRenderObject();
      if (mounted && box is RenderBox && box.hasSize) widget.onHeight(box.size.height);
    });
    return widget.child;
  }
}

enum _Phase { available, downloading, failed }

class _UpdateCard extends StatefulWidget {
  final UpdateInfo info;
  final GlobalKey<NavigatorState> navigatorKey;
  const _UpdateCard({super.key, required this.info, required this.navigatorKey});
  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> with SingleTickerProviderStateMixin {
  late final _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  _Phase _phase = _Phase.available;
  double _progress = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Reduced motion: appear in place, no slide.
      if (MediaQuery.of(context).disableAnimations) {
        _enter.value = 1;
      } else {
        _enter.forward();
      }
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
    });
    try {
      await updater.runUpdate(
        widget.info,
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      );
      // Android hands over to the system installer; desktop exits and
      // relaunches. Either way the card has nothing more to say.
    } catch (e, st) {
      debugPrint('In-app update failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        // An integrity failure will fail the same way again; say where to go.
        _error = e is IntegrityException
            ? "This update couldn't be verified. Download it from "
                'clippy.alwinpaul.me instead.'
            : "The download didn't finish. Nothing on this device changed.";
      });
    }
  }

  void _openNotes() {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx != null) showUpdateSheet(ctx, widget.info);
  }

  Future<void> _close() async {
    // Dismissing an AVAILABLE update remembers this version (Settings →
    // Check for updates still shows it). A failed one just closes.
    if (!MediaQuery.of(context).disableAnimations) await _enter.reverse();
    if (_phase == _Phase.available) {
      await updater.dismiss();
    } else {
      updater.available.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final info = widget.info;
    final curve = CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);
    final (title, body) = switch (_phase) {
      _Phase.available => (
          'Update available',
          'Clippy ${info.version} is ready. Your clips and pairing stay as they are.'
        ),
      _Phase.downloading => (
          'Downloading update',
          _progress >= 1
              ? 'Opening the installer…'
              : 'Downloading… ${(_progress * 100).round()}%'
        ),
      _Phase.failed => ('Update failed', _error),
    };

    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(1.1, 0), end: Offset.zero).animate(curve),
        child: Semantics(
          container: true,
          liveRegion: true,
          label: title,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: c.isDark ? c.borderStrong.withValues(alpha: 0.5) : c.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: c.isDark ? 0.5 : 0.08),
                    blurRadius: 24,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _phase == _Phase.failed ? c.rust : signalOrangeBright,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(title, style: Ct.body(15, weight: FontWeight.w700, color: c.ink)),
                      ),
                      if (_phase != _Phase.downloading)
                        IconButton(
                          // No `tooltip`: this sits above the Navigator, with
                          // no Overlay for a Tooltip to draw in.
                          onPressed: _close,
                          icon: Icon(Icons.close_rounded, size: 18, color: c.muted2,
                              semanticLabel: 'Dismiss update'),
                        )
                      else
                        const SizedBox(height: 48),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(body, style: Ct.body(13.5, color: c.muted2, height: 1.45)),
                  ),
                  if (_phase == _Phase.downloading) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          minHeight: 6,
                          value: _progress == 0 ? null : _progress,
                          color: scheme.secondary,
                          backgroundColor: scheme.surfaceContainerHigh,
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _openNotes,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        info.isBugUpdate ? 'See what got better' : "See what's new",
                        style: Ct.body(13.5, weight: FontWeight.w600, color: c.ink).copyWith(
                          decoration: TextDecoration.underline,
                          decorationColor: c.muted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _update,
                          child: Text(_phase == _Phase.failed ? 'Try again' : 'Update'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
