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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showUpdateSheet(context, info),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.green.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(Icons.system_update, size: 18, color: c.green),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Update available — v${info.version}',
                  style: Ct.body(13, weight: FontWeight.w500, color: c.ink),
                ),
              ),
              Text('View',
                  style: Ct.body(13.5, weight: FontWeight.w600, color: c.green)),
              IconButton(
                icon: Icon(Icons.close, size: 18, color: c.muted),
                onPressed: () => updater.dismiss(),
              ),
            ],
          ),
        ),
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
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
    final info = widget.info;
    final title = info.isBugUpdate
        ? 'Bug fixes & improvements'
        : 'New in ${info.version}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.system_update, color: c.green, size: 24),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: Ct.title(22, color: c.ink))),
              ],
            ),
            Text('Version ${info.version}',
                style: Ct.body(13, color: c.muted)),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Section('New Features', info.features, c),
                    _Section('New Improvements', info.improvements, c),
                    _Section('Bug Fixes', info.fixes, c),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: Ct.body(13, color: c.rust, height: 1.4)),
            ],
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
                              color: Ck.bg,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _progress == 0
                                ? 'Starting…'
                                : 'Downloading ${(_progress! * 100).round()}%',
                            style: Ct.body(15, weight: FontWeight.w600, color: Ck.bg),
                          ),
                        ],
                      )
                    : Text('Update now',
                        style: Ct.body(15, weight: FontWeight.w600, color: Ck.bg)),
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
  final List<String> items;
  final ClippyColors c;
  const _Section(this.title, this.items, this.c);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: Ct.sectionLabel().copyWith(color: c.muted)),
          const SizedBox(height: 6),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: Ct.body(14, color: c.green)),
                  Expanded(
                    child: Text(it, style: Ct.body(14, color: c.ink, height: 1.4)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
