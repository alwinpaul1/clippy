import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/history/history_item.dart';
import '../platform/foreground_service.dart';
import '../platform/haptics.dart';
import '../platform/share_channel.dart';
import '../core/pairing/pairing_key.dart';
import '../core/update/update_info.dart';
import 'clip_controller.dart';
import 'permission_help_sheet.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'theme_controller.dart';
import 'update_controller.dart';
import 'update_sheet.dart';

/// The main Clippy screen: synced clipboard history (tap to copy) under a
/// frosted-glass header with the living mascot, a manual add box, delete
/// (swipe / clear-all / multi-select), and access to settings + pairing.
class HomePage extends StatelessWidget {
  final ClipController controller;
  final PairingKey pairing;
  final ThemeController theme;
  final Future<void> Function() onUnpair;

  const HomePage({
    super.key,
    required this.controller,
    required this.pairing,
    required this.theme,
    required this.onUnpair,
  });

  /// One snackbar for the whole screen. The chip and its label both come from
  /// the theme's `snackBarTheme`, which uses the M3 inverse pair — so the label
  /// flips with the theme instead of being pinned to one palette's light value.
  static void snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        ),
      );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          theme: theme,
          onAddDevice: () => _showKey(context),
          onUnpair: onUnpair,
        ),
      ),
    );
  }

  void _showKey(BuildContext context) {
    final c = context.ck;
    final payload = pairing.toQrPayload();
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x8C15131A),
      builder: (context) => Dialog(
        backgroundColor: c.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add another device', style: Ct.title(24, color: c.ink)),
              const SizedBox(height: 16),
              Text(
                'Scan this on your other device, or paste the key:',
                style: Ct.body(14, color: c.muted2),
              ),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    // True white in both themes — a QR needs a real white
                    // quiet zone to scan reliably.
                    color: Colors.white,
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: QrImageView(data: payload, size: 150),
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(payload, style: Ct.mono(12, color: c.muted2)),
              ),
              const SizedBox(height: 18),
              // Styled by the filled-button theme, which carries the brand
              // fill and its matching foreground for both themes.
              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: payload));
                  Navigator.pop(context);
                  snack(context, 'Key copied');
                },
                icon: const Icon(Icons.copy_rounded, size: ClipIcons.inline),
                label: const Text('Copy key'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            if (!controller.ready) {
              return Center(child: CircularProgressIndicator(color: c.accent));
            }
            return _HomeBody(
              controller: controller,
              onDevices: () => _showKey(context),
              onSettings: () => _openSettings(context),
              onUnpair: onUnpair,
            );
          },
        ),
      ),
    );
  }
}

/// Stateful body owning the selection state, so it survives history updates.
class _HomeBody extends StatefulWidget {
  final ClipController controller;
  final VoidCallback onDevices;
  final VoidCallback onSettings;
  final Future<void> Function() onUnpair;
  const _HomeBody({
    required this.controller,
    required this.onDevices,
    required this.onSettings,
    required this.onUnpair,
  });

  @override
  State<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends State<_HomeBody> {
  final Set<String> _selected = {};
  final Set<String> _collapsedDevices = {};
  bool _selecting = false;

  void _toggleDevice(String device) {
    Haptics.tick();
    setState(() {
      if (!_collapsedDevices.remove(device)) _collapsedDevices.add(device);
    });
  }

  static String _deviceKey(HistoryItem i) =>
      i.device.isEmpty ? 'Unknown device' : i.device;

  /// One tap in the header folds/unfolds every device group, so a huge
  /// most-recent group never forces scrolling to reach the others.
  void _toggleAllDevices(List<HistoryItem> items) {
    Haptics.tick();
    final all = items.map(_deviceKey).toSet();
    setState(() {
      if (_collapsedDevices.length < all.length) {
        _collapsedDevices
          ..clear()
          ..addAll(all);
      } else {
        _collapsedDevices.clear();
      }
    });
  }
  // Clip ages ("2m") are computed at build time; without a periodic rebuild
  // they go stale, so two devices show different ages for the same clip.
  Timer? _agesTicker;

  ClipController get _ctl => widget.controller;

  @override
  void initState() {
    super.initState();
    _agesTicker = Timer.periodic(
      const Duration(seconds: 30),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _agesTicker?.cancel();
    super.dispose();
  }

  void _enterSelection(HistoryItem item) {
    Haptics.tick();
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(item.hash);
    });
  }

  void _toggle(HistoryItem item) {
    setState(() {
      if (!_selected.remove(item.hash)) _selected.add(item.hash);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _selectAll(List<HistoryItem> items) => setState(() {
    _selected
      ..clear()
      ..addAll(items.map((i) => i.hash));
  });

  Future<void> _copy(HistoryItem item) async {
    await _ctl.applyItem(item);
    if (mounted) HomePage.snack(context, 'Copied to clipboard');
  }

  // Turn 6: tapping a clip opens a preview (text sheet / image viewer) with
  // Copy as the primary action; the row's copy button still copies in one tap.
  void _openPreview(HistoryItem item) {
    if (item.isImage && item.imageBytes != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => _ImagePreview(
            item: item,
            onCopy: () => _copy(item),
            onDelete: () => _deleteOne(item),
          ),
        ),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _TextPreview(
          item: item,
          onCopy: () => _copy(item),
          onDelete: () => _deleteOne(item),
        ),
      );
    }
  }

  Future<void> _deleteOne(HistoryItem item) async {
    Haptics.thump();
    await _ctl.deleteItems([item]);
    if (mounted) HomePage.snack(context, 'Clip deleted');
  }

  Future<void> _deleteSelected(List<HistoryItem> all) async {
    final chosen = all.where((i) => _selected.contains(i.hash)).toList();
    final ok = await _confirm(
      title: 'Delete ${chosen.length} '
          '${chosen.length == 1 ? 'clip' : 'clips'}?',
      body: "They'll be removed from all your devices. This can't be undone.",
      action: 'Delete',
    );
    if (ok != true) return;
    // heavyImpact, not mediumImpact: Samsung maps mediumImpact (KEYBOARD_TAP)
    // to the keyboard-vibration setting and silently drops it when that's off.
    Haptics.thump();
    await _ctl.deleteItems(chosen);
    _exitSelection();
  }

  Future<void> _clearAll() async {
    final ok = await _confirm(
      title: 'Clear all clips?',
      body: 'This removes every clip from all your devices. Anything not '
          'saved elsewhere is gone for good.',
      action: 'Clear all',
    );
    if (ok == true) {
      // heavyImpact, not mediumImpact — see _deleteSelected.
      Haptics.thump();
      await _ctl.clearAll();
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
  }) {
    final c = context.ck;
    return showDialog<bool>(
      context: context,
      barrierColor: const Color(0x8C15131A),
      builder: (context) => Dialog(
        backgroundColor: c.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphPlate(
                icon: Icons.delete_rounded,
                base: Theme.of(context).colorScheme.error,
                size: 44,
              ),
              const SizedBox(height: 14),
              Text(title, style: Ct.title(22, color: c.ink)),
              const SizedBox(height: 8),
              Text(body, style: Ct.body(14, color: c.muted2, height: 1.5)),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(
                      'Cancel',
                      style: Ct.body(14, weight: FontWeight.w500, color: c.ink),
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: c.rust,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(
                      action,
                      style: Ct.body(14,
                          weight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onError),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _ctl.history;
    // Prune selection to items that still exist after remote deletes.
    final live = items.map((i) => i.hash).toSet();
    _selected.retainAll(live);
    if (_selecting && _selected.isEmpty && items.isEmpty) _selecting = false;
    final reconnecting = !_ctl.connected;

    return Stack(
      children: [
        Positioned.fill(
          child: items.isEmpty
              ? _EmptyState(onAddDevice: widget.onDevices)
              : _HistoryList(
                  items: items,
                  topInset: (_selecting ? 76 : 122) +
                      (defaultTargetPlatform == TargetPlatform.macOS ? 20 : 0),
                  selecting: _selecting,
                  selected: _selected,
                  collapsedDevices: _collapsedDevices,
                  onToggleDevice: _toggleDevice,
                  onCopy: _copy,
                  onDelete: _deleteOne,
                  onToggle: _toggle,
                  onLongPress: _enterSelection,
                  onPreview: _openPreview,
                ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          // Selection is a MODE — the bar swap announces it. A short fade +
          // drop makes the mode change legible without slowing anyone down;
          // this is the "containers may enter" budget, spent once.
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.06),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: _selecting
                ? _SelectionBar(
                    key: const ValueKey('selection-bar'),
                    count: _selected.length,
                    onClose: _exitSelection,
                    onSelectAll: () => _selectAll(items),
                    onDelete: () => _deleteSelected(items),
                  )
                : _GlassHeader(
                    key: const ValueKey('glass-header'),
                    reconnecting: reconnecting,
                    showClearAll: items.isNotEmpty,
                    showCollapseAll:
                        items.map(_deviceKey).toSet().length > 1,
                    allCollapsed: items.isNotEmpty &&
                        _collapsedDevices.length >=
                            items.map(_deviceKey).toSet().length,
                    onToggleCollapseAll: () => _toggleAllDevices(items),
                    onDevices: widget.onDevices,
                    onSettings: widget.onSettings,
                    onUnpair: widget.onUnpair,
                    onClearAll: _clearAll,
                  ),
          ),
        ),
        // Screenshot auto-sync can't work with "Select photos" (partial) or
        // denied photo access — a transient snackbar was too easy to miss, so
        // pin a banner until it's fixed. The lifecycle-resume refresh in
        // ClipController clears it once full access is granted.
        if (defaultTargetPlatform == TargetPlatform.android &&
            (_ctl.screenshotAccess == 'partial' ||
                _ctl.screenshotAccess == 'denied'))
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(child: _ShotAccessBanner()),
          ),
        // Background sync was enabled and has been switched off — almost
        // always because an app update took the accessibility service with
        // it. Shown ABOVE the photo-access banner's slot only when that one
        // is absent, so the two never stack on top of each other.
        if (defaultTargetPlatform == TargetPlatform.android &&
            _ctl.bgSyncRegressed &&
            _ctl.screenshotAccess != 'partial' &&
            _ctl.screenshotAccess != 'denied')
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(child: _BgSyncOffBanner()),
          ),
        // In-app update available.
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: SafeArea(
            child: ValueListenableBuilder<UpdateInfo?>(
              valueListenable: updater.available,
              builder: (context, info, _) =>
                  info == null ? const SizedBox.shrink() : UpdateBanner(info: info),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pinned warning: screenshots won't sync until Clippy has FULL photo access
/// (Android 14+ "Select photos" partial grants hide new screenshots entirely).
/// Pinned warning: background sync was ON and is now OFF.
///
/// Android drops an app's accessibility service on every reinstall, and that
/// includes Clippy's own in-app update — so the feature the user deliberately
/// enabled goes away silently, and the app keeps looking healthy because it
/// still syncs whenever it is open. Tapping through re-runs the same help
/// sheet as first-time setup.
class _BgSyncOffBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return _WarnBanner(
      icon: Icons.sync_problem_rounded,
      message: 'Background sync turned off — the last update reset it.',
      onFix: () => showPermissionHelpSheet(
        context,
        title: 'Enable background sync',
        whatFor: "Android switches this off whenever Clippy updates. "
            'Turn it back on and copies will sync again while the app '
            'is closed.',
        onOpenSettings: ShareChannel.openA11ySettings,
      ),
      c: c,
    );
  }
}

class _ShotAccessBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return _WarnBanner(
      icon: Icons.screenshot_monitor_rounded,
      message: "Screenshots won't sync — Clippy needs full photo access.",
      onFix: ShareChannel.openPhotoSettings,
      c: c,
    );
  }
}

/// The one pinned-warning shape. Both warnings on this screen were the same
/// 40 lines with two words changed, so they are one widget now — the next
/// warning inherits the treatment instead of copying it a third time.
///
/// The error tint carries the alarm, so the surface stays the ordinary card:
/// a fully red banner over the list reads as a crash, and neither of these
/// states is one. The clip list keeps working while they show.
class _WarnBanner extends StatelessWidget {
  final IconData icon;
  final String message;
  final VoidCallback onFix;
  final ClippyColors c;
  const _WarnBanner({
    required this.icon,
    required this.message,
    required this.onFix,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          GlyphPlate(icon: icon, base: scheme.error, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: Ct.body(12.5, color: c.ink)),
          ),
          TextButton(
            onPressed: onFix,
            child: Text(
              'Fix',
              style: Ct.body(13.5, weight: FontWeight.w700, color: c.accent),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassHeader extends StatelessWidget {
  final bool reconnecting;
  final bool showClearAll;
  final bool showCollapseAll;
  final bool allCollapsed;
  final VoidCallback onToggleCollapseAll;
  final VoidCallback onDevices;
  final VoidCallback onSettings;
  final Future<void> Function() onUnpair;
  final VoidCallback onClearAll;
  const _GlassHeader({
    super.key,
    required this.reconnecting,
    required this.showClearAll,
    required this.showCollapseAll,
    required this.allCollapsed,
    required this.onToggleCollapseAll,
    required this.onDevices,
    required this.onSettings,
    required this.onUnpair,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return ClipRect(
      child: BackdropFilter(
        // Stronger blur + lower tint = a more see-through "liquid glass" bar.
        filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                c.bg.withValues(alpha: c.isDark ? 0.52 : 0.60),
                c.bg.withValues(alpha: c.isDark ? 0.38 : 0.46),
              ],
            ),
            border: Border(
              bottom: BorderSide(color: c.ink.withValues(alpha: 0.06)),
            ),
          ),
          // Extra top padding on macOS so the logo clears the traffic-light
          // buttons (the title bar is transparent, so content underlaps them).
          padding: EdgeInsets.fromLTRB(
            20,
            defaultTargetPlatform == TargetPlatform.macOS ? 30 : 10,
            12,
            4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // The header mark and wordmark are kept from the previous
                  // design at the owner's request: the mascot is plain INK,
                  // not the brand violet, and the wordmark keeps its serif.
                  // The violet system runs everywhere else; this one bar is
                  // the app's own signature and it stays as it was.
                  AnimatedClippyMark(
                    height: 40,
                    clipHex: c.hex(c.ink),
                    eyeHex: c.hex(c.ink),
                    eyeFill: c.hex(c.bg),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Clippy', style: Ct.wordmark(27, color: c.ink)),
                  ),
                  _HeaderIcon(
                    icon: Icons.devices_rounded,
                    tooltip: 'Add another device',
                    color: c.ink,
                    onTap: onDevices,
                  ),
                  _HeaderIcon(
                    icon: Icons.settings_rounded,
                    tooltip: 'Settings',
                    color: c.ink,
                    onTap: onSettings,
                  ),
                  _HeaderIcon(
                    icon: Icons.logout_rounded,
                    tooltip: 'Unpair this device',
                    color: c.ink,
                    onTap: () => onUnpair(),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 8, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: ValueListenableBuilder<bool>(
                        // A green "Synced" dot only ever meant "the UI's own
                        // connection is up" — it stayed green through a
                        // six-hour background-sync outage. Tell the truth.
                        valueListenable:
                            ForegroundServiceManager.backgroundSyncAlive,
                        builder: (context, bgAlive, _) {
                          final warn = reconnecting || !bgAlive;
                          final label = reconnecting
                              ? 'Reconnecting…'
                              : (bgAlive
                                  ? 'Synced'
                                  // The app is open — "open Clippy" would be an
                                  // instruction the user cannot follow. Say what
                                  // is true; the health watch is already
                                  // retrying in the background.
                                  : 'Background sync stopped — retrying');
                          return Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: warn ? c.rust : c.syncOk,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 9),
                              Flexible(
                                child: Text(
                                  label,
                                  overflow: TextOverflow.ellipsis,
                                  style: Ct.body(
                                    13,
                                    color: warn ? c.rust : c.muted2,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (showCollapseAll) ...[
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: onToggleCollapseAll,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            // borderStrong (M3 `outline`), NOT border
                            // (`outlineVariant`): this hairline is the ONLY
                            // thing that draws this control's boundary, so
                            // WCAG 1.4.11 wants 3:1 and outlineVariant is
                            // ~1.4:1 on these surfaces. See docs/DESIGN.md.
                            border: Border.all(color: c.borderStrong),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                allCollapsed
                                    ? Icons.unfold_more_rounded
                                    : Icons.unfold_less_rounded,
                                size: 14,
                                color: c.muted2,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                allCollapsed ? 'Expand' : 'Collapse',
                                style: Ct.body(
                                  12,
                                  weight: FontWeight.w500,
                                  color: c.muted2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (showClearAll)
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: onClearAll,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            // borderStrong (M3 `outline`), NOT border
                            // (`outlineVariant`): this hairline is the ONLY
                            // thing that draws this control's boundary, so
                            // WCAG 1.4.11 wants 3:1 and outlineVariant is
                            // ~1.4:1 on these surfaces. See docs/DESIGN.md.
                            border: Border.all(color: c.borderStrong),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.delete_rounded,
                                size: 14,
                                color: c.rust,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'Clear all',
                                style: Ct.body(
                                  12,
                                  weight: FontWeight.w500,
                                  color: c.rust,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onDelete;
  const _SelectionBar({
    super.key,
    required this.count,
    required this.onClose,
    required this.onSelectAll,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    // The gradient's other appearance in the app. Selection is a mode, not a
    // decoration: the whole bar changing to the brand is what tells you the
    // list now behaves differently.
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: brandGradient),
      // No SafeArea here: HomePage's body already sits inside one, so the top
      // inset is spent by the time this bar is built.
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Leave selection',
              icon: Icon(Icons.close_rounded, color: c.onBrand, size: ClipIcons.nav),
              onPressed: onClose,
            ),
            Expanded(
              child: Text(
                '$count selected',
                style: Ct.title(19, color: c.onBrand),
              ),
            ),
            IconButton(
              tooltip: 'Select all',
              icon: Icon(Icons.done_all_rounded, color: c.onBrand, size: ClipIcons.nav),
              onPressed: onSelectAll,
            ),
            IconButton(
              tooltip: 'Delete selected',
              icon: Icon(Icons.delete_rounded, color: c.onBrand, size: ClipIcons.nav),
              onPressed: count == 0 ? null : onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;
  const _HeaderIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: color, size: 21),
      onPressed: onTap,
    );
  }
}

class _HistoryList extends StatelessWidget {
  final List<HistoryItem> items;
  final double topInset;
  final bool selecting;
  final Set<String> selected;
  final Set<String> collapsedDevices;
  final void Function(String) onToggleDevice;
  final Future<void> Function(HistoryItem) onCopy;
  final Future<void> Function(HistoryItem) onDelete;
  final void Function(HistoryItem) onToggle;
  final void Function(HistoryItem) onLongPress;
  final void Function(HistoryItem) onPreview;
  const _HistoryList({
    required this.items,
    required this.topInset,
    required this.selecting,
    required this.selected,
    required this.collapsedDevices,
    required this.onToggleDevice,
    required this.onCopy,
    required this.onDelete,
    required this.onToggle,
    required this.onLongPress,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    // Group clips by the device they came from; order the groups so the device
    // with the most recent clip comes first, and keep each group newest-first.
    final byDevice = <String, List<HistoryItem>>{};
    for (final item in items) {
      final key = item.device.isEmpty ? 'Unknown device' : item.device;
      (byDevice[key] ??= []).add(item);
    }
    DateTime newestOf(List<HistoryItem> l) =>
        l.map((i) => i.timestamp).reduce((a, b) => a.isAfter(b) ? a : b);
    final devices = byDevice.keys.toList()
      ..sort((a, b) => newestOf(byDevice[b]!).compareTo(newestOf(byDevice[a]!)));
    for (final device in devices) {
      final clips = byDevice[device]!
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final collapsed = collapsedDevices.contains(device);
      children.add(
        _DeviceHeader(
          device: device,
          count: clips.length,
          collapsed: collapsed,
          first: device == devices.first,
          onTap: () => onToggleDevice(device),
        ),
      );
      if (collapsed) continue;
      for (final item in clips) {
        children.add(
          _ClipTile(
            key: ValueKey(item.hash),
            item: item,
            // The single newest clip in the whole list gets the hero
            // treatment: it is the clip the user opened the app to paste.
            // Groups are newest-first, so it is the first row of the first
            // group — same list slot, same interactions, larger clothes.
            latest: device == devices.first && item == clips.first,
            selecting: selecting,
            selected: selected.contains(item.hash),
            onTap: () => selecting ? onToggle(item) : onPreview(item),
            onCopy: () => onCopy(item),
            onLongPress: () => onLongPress(item),
            onDelete: () => onDelete(item),
          ),
        );
      }
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        20,
        topInset,
        20,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      itemCount: children.length,
      separatorBuilder: (_, i) =>
          SizedBox(height: children[i] is _ClipTile ? 10 : 0),
      itemBuilder: (_, i) => children[i],
    );
  }
}

/// A device group's header, redesigned from a bare ALL-CAPS label into an
/// identity object: the device's tinted circle mark (platform glyph, letter
/// fallback), its name, a count pill, and the fold chevron moved to the
/// trailing edge where disclosure lives. The mark's colour is the same one
/// the group's clip rows repeat on their kind plates — colour says WHERE,
/// glyph says WHAT.
class _DeviceHeader extends StatelessWidget {
  final String device;
  final int count;
  final bool collapsed;
  final bool first;
  final VoidCallback onTap;
  const _DeviceHeader({
    required this.device,
    required this.count,
    required this.collapsed,
    required this.first,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final glyph = deviceGlyph(device);
    final letter = device.trim().isEmpty ? '?' : device.trim()[0].toUpperCase();
    return Padding(
      padding: EdgeInsets.only(top: first ? 8 : 18, bottom: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(
            children: [
              GlyphPlate(
                icon: glyph,
                letter: glyph == null ? letter : null,
                base: deviceTint(scheme, device),
                size: 26,
                circle: true,
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  device,
                  style: Ct.body(13, weight: FontWeight.w700, color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('$count', style: Ct.mono(11, color: c.muted2)),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: collapsed ? -0.25 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(Icons.keyboard_arrow_down_rounded,
                    size: 18, color: c.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A clip row as a designed object, not a row of Text: a leading mark that
/// says what the clip IS (image thumbnail, or a kind glyph on a plate tinted
/// with the source device's colour), a two-line preview, a legible meta line
/// (kind · size · age), and a copy button that confirms with a tick.
///
/// The single newest clip in the list renders with `latest: true`: a bigger
/// preview, a LATEST chip, and a 24 radius. It is the reason the app was
/// opened — the hierarchy should say so.
class _ClipTile extends StatelessWidget {
  final HistoryItem item;
  final bool latest;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  const _ClipTile({
    super.key,
    required this.item,
    required this.latest,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onCopy,
    required this.onLongPress,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final kind = _kindOf(item);
    final thumb = item.isImage && item.imageBytes != null;
    final thumbSide = latest ? 64.0 : 46.0;
    final card = ClipCard(
      radius: latest ? 24 : 20,
      color: selected ? c.selBg : null,
      highlighted: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      padding: EdgeInsets.fromLTRB(16, latest ? 16 : 14, 14, latest ? 16 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (selecting) ...[
            _Check(selected: selected),
            const SizedBox(width: 13),
          ],
          if (thumb) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(latest ? 14 : 12),
              child: Image.memory(
                item.imageBytes!,
                width: thumbSide,
                height: thumbSide,
                fit: BoxFit.cover,
                cacheWidth: 128,
                gaplessPlayback: true,
              ),
            ),
            const SizedBox(width: 13),
          ] else ...[
            GlyphPlate(
              icon: _kindGlyph(kind),
              base: deviceTint(scheme, item.device),
              size: 40,
            ),
            const SizedBox(width: 13),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (latest) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color:
                          c.accent.withValues(alpha: c.isDark ? 0.22 : 0.12),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      'LATEST',
                      style: TextStyle(
                        fontFamily: appFontFamily,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.9,
                        color: c.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 7),
                ],
                Text(
                  item.isImage ? 'Image' : item.text,
                  maxLines: latest ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: kind == _ClipKind.code
                      ? Ct.mono(14, color: c.ink)
                      : Ct.body(latest ? 15.5 : 15,
                          weight: FontWeight.w500, color: c.ink),
                ),
                const SizedBox(height: 5),
                Text(_meta(item, kind), style: Ct.mono(11, color: c.muted)),
              ],
            ),
          ),
          if (!selecting) ...[
            const SizedBox(width: 14),
            _CopyButton(onCopy: onCopy),
          ],
        ],
      ),
    );

    if (selecting) return card;
    // Swipe-left to delete. confirmDismiss triggers the delete and returns
    // false so the row isn't self-removed — the history rebuild removes it.
    return Dismissible(
      key: ValueKey('dismiss-${item.hash}'),
      direction: DismissDirection.endToStart,
      // Half swipe deletes (with the armed tick as the cue).
      dismissThresholds: const {DismissDirection.endToStart: 0.4},
      onUpdate: (d) {
        // Tick the instant the swipe crosses (or backs out of) the delete
        // threshold. heavyImpact, not selectionClick: Samsung gates the
        // subtle constants (CLOCK_TICK/VIRTUAL_KEY) behind system settings.
        if (d.reached != d.previousReached) Haptics.tick();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        decoration: BoxDecoration(
          color: c.rust,
          borderRadius: BorderRadius.circular(latest ? 24 : 20),
        ),
        child: Icon(Icons.delete_rounded,
            color: Theme.of(context).colorScheme.onError, size: 20),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: card,
    );
  }
}

/// The row's copy affordance. Tapping flashes a tick for a moment — the copy
/// happens instantly and invisibly, so the button itself is the one place
/// that can confirm it happened. Motion budget: 180 ms, one icon.
class _CopyButton extends StatefulWidget {
  final VoidCallback onCopy;
  const _CopyButton({required this.onCopy});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  Timer? _reset;
  bool _copied = false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _tap() {
    widget.onCopy();
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Tooltip(
      message: 'Copy',
      child: GestureDetector(
        onTap: _tap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accent.withValues(alpha: c.isDark ? 0.18 : 0.09),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              key: ValueKey(_copied),
              size: ClipIcons.inline,
              color: c.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool selected;
  const _Check({required this.selected});
  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    // A FILLED brand chip, so it takes the same fill the filled buttons take —
    // not `c.accent`, which is the lighter INK violet in dark mode and would
    // leave a white tick at roughly 2:1 on it.
    final fill =
        c.isDark ? primaryFillDark : Theme.of(context).colorScheme.primary;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? fill : Colors.transparent,
        border: Border.all(
          color: selected ? fill : c.borderStrong,
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
          : null,
    );
  }
}

/// The designed empty state: mascot, a real title, one honest sentence, and
/// the one action that actually helps — pairing another device (an empty list
/// usually means this is the only device in the group). The old copy said
/// "add one below" and there was nothing below; now the promised control
/// exists and the copy tells no lies.
class _EmptyState extends StatelessWidget {
  final VoidCallback onAddDevice;
  const _EmptyState({required this.onAddDevice});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: 0.5,
                // Alive like the header mark (gentle bob + blink): an empty
                // room shouldn't feel dead — Clippy is waiting, not broken.
                child: AnimatedClippyMark(
                  height: 64,
                  clipHex: c.hex(c.muted2),
                  eyeHex: c.hex(c.muted2),
                  eyeFill: c.hex(c.bg),
                ),
              ),
              const SizedBox(height: 20),
              Text('Nothing here yet',
                  textAlign: TextAlign.center,
                  style: Ct.title(20, color: c.ink)),
              const SizedBox(height: 8),
              Text(
                'Copy something on any paired device and it lands here, '
                'ready to paste.',
                textAlign: TextAlign.center,
                style: Ct.body(14, color: c.muted2),
              ),
              const SizedBox(height: 24),
              ClipCard(
                radius: 18,
                onTap: onAddDevice,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.devices_rounded,
                        size: ClipIcons.inline, color: c.accent),
                    const SizedBox(width: 10),
                    Text('Add another device',
                        style: Ct.body(14.5,
                            weight: FontWeight.w600, color: c.ink)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Turn 6a: text clip preview — an expanding bottom sheet with the full
/// content and Copy (primary) / Delete actions.
class _TextPreview extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  const _TextPreview({
    required this.item,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final kind = _kindOf(item);
    final dev = item.device.isEmpty ? '' : '${item.device} · ';
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      decoration: BoxDecoration(
        color: c.dialogBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        10,
        20,
        20 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetGrabber(),
          // The same mark language as the list row: the clip's kind on the
          // source device's tint, so the sheet visibly belongs to its row.
          Row(
            children: [
              GlyphPlate(
                icon: _kindGlyph(kind),
                base: deviceTint(scheme, item.device),
                size: 28,
              ),
              const SizedBox(width: 9),
              Text(_kindLabel(kind).toUpperCase(),
                  style: Ct.sectionLabel(color: c.muted)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '· $dev${_rel(item.timestamp)} · ${item.text.length} chars',
                  style: Ct.mono(11, color: c.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Flexible(
            child: ClipCard(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  child: SelectableText(
                    item.text,
                    style: Ct.body(16, color: c.ink, height: 1.55),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    onCopy();
                  },
                  icon: const Icon(Icons.copy_rounded, size: ClipIcons.inline),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 10),
              _SquareIconBtn(
                icon: Icons.delete_rounded,
                color: c.rust,
                border: c.rust.withValues(alpha: 0.35),
                bg: c.surface,
                onTap: () {
                  Navigator.pop(context);
                  onDelete();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Turn 6b: image clip preview — a full-screen viewer with Copy image / Delete.
class _ImagePreview extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  const _ImagePreview({
    required this.item,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Fixed dark chrome in BOTH themes, like the QR scanner: an image viewer
    // that repaints its frame white washes out the picture it exists to show.
    const bg = scannerBg;
    const fg = Colors.white;
    const meta = Color(0xFF9590A0); // dark-scheme `outline`
    const danger = Color(0xFFFFB4AB); // dark-scheme `error`
    final kb = ((item.imageBytes?.length ?? 0) / 1024).round();
    final fmt = item.mime.contains('png') ? 'PNG' : 'JPG';
    final dev = item.device.isEmpty ? '' : '${item.device} · ';
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: fg),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Image',
                            style: Ct.body(16, weight: FontWeight.w500, color: fg)),
                        Text('$fmt · $kb KB · $dev${_rel(item.timestamp)}',
                            style: Ct.mono(10.5, color: meta)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: item.imageBytes != null
                    ? InteractiveViewer(
                        minScale: 1,
                        maxScale: 6,
                        clipBehavior: Clip.none,
                        child: Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.memory(item.imageBytes!,
                                fit: BoxFit.contain),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 12, 20, 16 + MediaQuery.of(context).padding.bottom),
              child: Row(
                children: [
                  Expanded(
                    // primaryFillDark, not the dark scheme's `primary`: white
                    // ink needs 4.5:1 and only the darker fill gives it.
                    child: Material(
                      color: primaryFillDark,
                      borderRadius: BorderRadius.circular(18),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(context);
                          onCopy();
                        },
                        child: Container(
                          height: 50,
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.copy_rounded,
                                  size: ClipIcons.inline, color: fg),
                              const SizedBox(width: 9),
                              Text('Copy image',
                                  style: Ct.body(14.5,
                                      weight: FontWeight.w600, color: fg)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _SquareIconBtn(
                    icon: Icons.delete_rounded,
                    color: danger,
                    // 0.45, not 0.35: composited over `bg` the fainter ring
                    // measured 2.36:1 against the 3:1 WCAG 1.4.11 floor, and
                    // this ring is the delete button's only boundary. Raising
                    // the alpha fixes it here without moving the `danger`
                    // token, which the delete GLYPH also uses (10.85:1).
                    border: danger.withValues(alpha: 0.45),
                    bg: bg,
                    onTap: () {
                      Navigator.pop(context);
                      onDelete();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SquareIconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color border;
  final Color bg;
  final VoidCallback onTap;
  const _SquareIconBtn({
    required this.icon,
    required this.color,
    required this.border,
    required this.bg,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

// --- helpers ---

/// What a clip IS, for the row's mark and meta line. Four kinds only — the
/// distinctions a user acts on (open a link, run a command, view an image,
/// paste text). Finer taxonomy would be decoration.
enum _ClipKind { text, link, code, image }

_ClipKind _kindOf(HistoryItem item) {
  if (item.isImage) return _ClipKind.image;
  final t = item.text.trim();
  if (RegExp(r'^https?://\S+$').hasMatch(t) ||
      RegExp(r'^www\.\S+$').hasMatch(t)) {
    return _ClipKind.link;
  }
  if (_looksLikeCode(t)) return _ClipKind.code;
  return _ClipKind.text;
}

IconData _kindGlyph(_ClipKind kind) => switch (kind) {
      _ClipKind.text => Icons.notes_rounded,
      _ClipKind.link => Icons.link_rounded,
      _ClipKind.code => Icons.terminal_rounded,
      _ClipKind.image => Icons.image_rounded,
    };

String _kindLabel(_ClipKind kind) => switch (kind) {
      _ClipKind.text => 'Text',
      _ClipKind.link => 'Link',
      _ClipKind.code => 'Code',
      _ClipKind.image => 'Image',
    };

bool _looksLikeCode(String s) {
  final t = s.trim();
  if (t.length > 60 || t.contains('\n')) return false;
  return RegExp(r'^[\d\s]+$').hasMatch(t) ||
      RegExp(r'(sudo |docker |git |npm |cd |\$ |curl )').hasMatch(t);
}

String _rel(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

String _meta(HistoryItem item, _ClipKind kind) {
  // No device here: the list groups by device, so the section header carries
  // it. (The full-screen / bottom-sheet previews still show the device.)
  // Kind first, size when it means something, age last — the same order the
  // eye asks the questions in.
  final rel = _rel(item.timestamp);
  if (item.isImage) {
    final kb = ((item.imageBytes?.length ?? 0) / 1024).round();
    final fmt = item.mime.contains('png') ? 'PNG' : 'JPG';
    return '$fmt · $kb KB · $rel';
  }
  final label = _kindLabel(kind);
  // Length only when the preview visibly truncates — "12 chars" is noise.
  if (item.text.length >= 100) {
    return '$label · ${item.text.length} chars · $rel';
  }
  return '$label · $rel';
}
