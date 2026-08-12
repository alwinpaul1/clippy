import 'package:flutter/material.dart';

import '../core/update/update_info.dart';
import '../platform/updater/platform_updater.dart';
import 'theme.dart';
import 'update_controller.dart';

/// Home-screen banner shown when an update is available. Tapping it opens the
/// changelog sheet; the trailing × dismisses this version.
class UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  const UpdateBanner({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    // The same banner anatomy as the home screen's warnings, plate, message,
    // action, so every pinned strip in the app is one shape. Only the tint
    // differs: brand violet, because an update is news, not a fault.
    return ClipCard(
      radius: 20,
      highlighted: true,
      onTap: () => showUpdateSheet(context, info),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          GlyphPlate(
            icon: Icons.download_rounded,
            base: Theme.of(context).colorScheme.primary,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Update available: v${info.version}',
              style: Ct.body(13.5, weight: FontWeight.w600, color: c.ink),
            ),
          ),
          Text('View',
              style: Ct.body(13.5, weight: FontWeight.w700, color: c.accent)),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 18, color: c.muted),
            tooltip: 'Dismiss this version',
            onPressed: () => updater.dismiss(),
          ),
        ],
      ),
    );
  }
}

/// Opens the changelog sheet with a single Update button.
Future<void> showUpdateSheet(BuildContext context, UpdateInfo info) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.ck.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => _UpdateSheet(info: info),
  );
}

class _UpdateSheet extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateSheet({required this.info});
  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  double? _progress; // null = not started; 0..1 downloading
  String? _error;

  Future<void> _update() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      await updater.runUpdate(
        widget.info,
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      );
      // On Android the OS installer takes over; on desktop the app exits and
      // relaunches. Nothing more to do here.
    } catch (e, st) {
      debugPrint('In-app update failed: $e\n$st');
      if (mounted) {
        setState(() {
          _progress = null;
          // An integrity failure is not a transient hiccup: the download did
          // not match what we published, so "try again" will just fail the same
          // way. Send the user to the site (a plain HTTPS browser download)
          // instead. Everything else IS retryable.
          _error = e is IntegrityException
              ? "This update couldn't be verified. Please download it from "
                  'the site instead.'
              : "Couldn't update. Try again, or download from the site.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final info = widget.info;
    final title = info.isBugUpdate
        ? 'Bug fixes & improvements'
        : 'New in ${info.version}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetGrabber(),
            // The version hero is the gradient's one appearance here, and it
            // shows ONLY for a feature release. A bug release is deliberately
            // framed as "what got better", with no version to celebrate, the
            // project's own release rule, kept visible in the design.
            if (!info.isBugUpdate) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                decoration: BoxDecoration(
                  gradient: brandGradient,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('NEW VERSION',
                        style: Ct.sectionLabel(
                            color: Colors.white.withValues(alpha: 0.75))),
                    const SizedBox(height: 6),
                    Text(info.version,
                        style: Ct.title(30, color: c.onBrand)),
                  ],
                ),
              ),
              const SizedBox(height: 18),
            ],
            Text(title, style: Ct.title(22, color: c.ink)),
            if (info.isBugUpdate) ...[
              const SizedBox(height: 4),
              Text('Version ${info.version}', style: Ct.body(13, color: c.muted)),
            ],
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Each section gets its own mark on its own scheme role,
                    // three GlyphPlates from the same family as the rest of
                    // the app, and the one place Clippy's lighter hand shows
                    // in this sheet. Features = spark, improvements = up,
                    // fixes = bug. The lists themselves stay quiet dots.
                    _Section('New Features', Icons.auto_awesome_rounded,
                        scheme.primary, info.features, c),
                    _Section('Improvements', Icons.trending_up_rounded,
                        scheme.tertiary, info.improvements, c),
                    _Section('Bug Fixes', Icons.bug_report_rounded,
                        scheme.secondary, info.fixes, c),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                // The M3 error pair carries its own contrast in both themes, so
                // this needs no per-theme branch.
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(_error!,
                    style: Ct.body(13, color: scheme.onErrorContainer)),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              // Styled by the filled-button theme, which already picks the
              // right fill per theme. See permission_help_sheet.dart.
              child: FilledButton(
                onPressed: _progress != null ? null : _update,
                child: _progress != null
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: _progress == 0 ? null : _progress,
                              color: scheme.onPrimary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(_progress == 0
                              ? 'Starting…'
                              : 'Downloading ${(_progress! * 100).round()}%'),
                        ],
                      )
                    : const Text('Update now'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color base;
  final List<String> items;
  final ClippyColors c;
  const _Section(this.title, this.icon, this.base, this.items, this.c);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlyphPlate(icon: icon, base: base, size: 24),
              const SizedBox(width: 8),
              Text(title.toUpperCase(),
                  style: Ct.sectionLabel(color: c.muted)),
            ],
          ),
          const SizedBox(height: 10),
          for (final it in items)
            Padding(
              // Indented to the section title's text edge, so the list reads
              // as the plate's content rather than a second left margin.
              padding: const EdgeInsets.only(bottom: 6, left: 32),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: 10),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration:
                          BoxDecoration(color: c.accent, shape: BoxShape.circle),
                    ),
                  ),
                  Expanded(child: Text(it, style: Ct.body(14, color: c.ink))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
