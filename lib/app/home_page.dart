import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/history/history_item.dart';
import '../platform/haptics.dart';
import '../core/pairing/pairing_key.dart';
import 'clip_controller.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'theme_controller.dart';

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

  static void snack(BuildContext context, String text) {
    final c = context.ck;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text, style: Ct.body(13.5, color: Ck.bg)),
          backgroundColor: c.snack,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
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
      barrierColor: const Color(0x731E1C15),
      builder: (context) => Dialog(
        backgroundColor: c.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: QrImageView(data: payload, size: 150),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: c.bg,
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(payload, style: Ct.mono(12, color: c.muted2)),
              ),
              const SizedBox(height: 18),
              Material(
                color: c.green,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: payload));
                    Navigator.pop(context);
                    snack(context, 'Key copied');
                  },
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.content_copy_outlined,
                          size: 16,
                          color: c.isDark ? c.bg : Ck.bg,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Copy key',
                          style: Ct.body(
                            14,
                            weight: FontWeight.w500,
                            color: c.isDark ? c.bg : Ck.bg,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
              return Center(child: CircularProgressIndicator(color: c.green));
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
  bool _selecting = false;
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
      barrierColor: const Color(0x731E1C15),
      builder: (context) => Dialog(
        backgroundColor: c.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.rust.withValues(alpha: 0.14),
                ),
                child: Icon(Icons.delete_outline, color: c.rust, size: 22),
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
                      style: Ct.body(14, weight: FontWeight.w500, color: Ck.bg),
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
              ? const _EmptyState()
              : _HistoryList(
                  items: items,
                  topInset: _selecting ? 76 : 122,
                  selecting: _selecting,
                  selected: _selected,
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
          child: _selecting
              ? _SelectionBar(
                  count: _selected.length,
                  onClose: _exitSelection,
                  onSelectAll: () => _selectAll(items),
                  onDelete: () => _deleteSelected(items),
                )
              : _GlassHeader(
                  reconnecting: reconnecting,
                  showClearAll: items.isNotEmpty,
                  onDevices: widget.onDevices,
                  onSettings: widget.onSettings,
                  onUnpair: widget.onUnpair,
                  onClearAll: _clearAll,
                ),
        ),
      ],
    );
  }
}

class _GlassHeader extends StatelessWidget {
  final bool reconnecting;
  final bool showClearAll;
  final VoidCallback onDevices;
  final VoidCallback onSettings;
  final Future<void> Function() onUnpair;
  final VoidCallback onClearAll;
  const _GlassHeader({
    required this.reconnecting,
    required this.showClearAll,
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
          padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AnimatedClippyMark(
                    height: 40,
                    clipHex: c.hex(c.ink),
                    eyeHex: c.hex(c.ink),
                    eyeFill: c.hex(c.bg),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Clippy', style: Ct.title(27, color: c.ink)),
                  ),
                  _HeaderIcon(
                    icon: Icons.devices_outlined,
                    tooltip: 'Add another device',
                    color: c.ink,
                    onTap: onDevices,
                  ),
                  _HeaderIcon(
                    icon: Icons.settings_outlined,
                    tooltip: 'Settings',
                    color: c.ink,
                    onTap: onSettings,
                  ),
                  _HeaderIcon(
                    icon: Icons.logout,
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
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: reconnecting ? c.rust : c.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        reconnecting ? 'Reconnecting…' : 'Synced',
                        style: Ct.body(
                          13,
                          color: reconnecting ? c.rust : c.muted2,
                        ),
                      ),
                    ),
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
                            border: Border.all(color: c.border),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.delete_outline,
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
    required this.count,
    required this.onClose,
    required this.onSelectAll,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Material(
      color: c.green,
      elevation: 2,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.close, color: Ck.bg, size: 22),
              onPressed: onClose,
            ),
            Expanded(
              child: Text(
                '$count selected',
                style: Ct.body(20, weight: FontWeight.w500, color: Ck.bg),
              ),
            ),
            IconButton(
              tooltip: 'Select all',
              icon: Icon(Icons.done_all, color: Ck.bg, size: 22),
              onPressed: onSelectAll,
            ),
            IconButton(
              tooltip: 'Delete selected',
              icon: Icon(Icons.delete_outline, color: Ck.bg, size: 22),
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
    required this.onCopy,
    required this.onDelete,
    required this.onToggle,
    required this.onLongPress,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    String? lastLabel;
    for (final item in items) {
      final label = _dayLabel(item.timestamp);
      if (label != lastLabel) {
        children.add(
          Padding(
            padding: EdgeInsets.only(
              // The first label sits just below the glass header — give it
              // room so it never renders half-faded under the blur.
              top: lastLabel == null ? 8 : 12,
              bottom: 2,
            ),
            child: Text(
              label,
              style: Ct.sectionLabel().copyWith(color: context.ck.muted),
            ),
          ),
        );
        lastLabel = label;
      }
      children.add(
        _ClipCard(
          key: ValueKey(item.hash),
          item: item,
          selecting: selecting,
          selected: selected.contains(item.hash),
          onTap: () => selecting ? onToggle(item) : onPreview(item),
          onCopy: () => onCopy(item),
          onLongPress: () => onLongPress(item),
          onDelete: () => onDelete(item),
        ),
      );
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
          SizedBox(height: children[i] is _ClipCard ? 10 : 0),
      itemBuilder: (_, i) => children[i],
    );
  }
}

class _ClipCard extends StatelessWidget {
  final HistoryItem item;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  const _ClipCard({
    super.key,
    required this.item,
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
    final card = Material(
      color: selected ? c.selBg : c.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Ink(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? c.green : c.border,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: c.isDark || selected
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x0A1E1C15),
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (selecting) ...[
                _Check(selected: selected),
                const SizedBox(width: 13),
              ],
              if (item.isImage && item.imageBytes != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    item.imageBytes!,
                    width: 46,
                    height: 46,
                    fit: BoxFit.cover,
                    cacheWidth: 128,
                    gaplessPlayback: true,
                  ),
                ),
                const SizedBox(width: 13),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.isImage ? 'Image' : item.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: (!item.isImage && _looksLikeCode(item.text))
                          ? Ct.mono(14, color: c.ink, weight: FontWeight.w500)
                          : Ct.body(15, weight: FontWeight.w500, color: c.ink),
                    ),
                    const SizedBox(height: 5),
                    Text(_meta(item), style: Ct.mono(11, color: c.muted)),
                  ],
                ),
              ),
              if (!selecting) ...[
                const SizedBox(width: 14),
                GestureDetector(
                  onTap: onCopy,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.border),
                    ),
                    child: Icon(
                      Icons.content_copy_outlined,
                      size: 15,
                      color: c.green,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
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
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline, color: Ck.bg, size: 20),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: card,
    );
  }
}

class _Check extends StatelessWidget {
  final bool selected;
  const _Check({required this.selected});
  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? c.green : Colors.transparent,
        border: Border.all(
          color: selected ? c.green : c.borderStrong,
          width: 2,
        ),
      ),
      child: selected
          ? Icon(Icons.check, size: 15, color: Ck.bg)
          : null,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 52),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.4,
              child: ClippyMark(
                height: 58,
                clipHex: c.hex(c.muted2),
                eyeHex: c.hex(c.muted2),
                eyeFill: c.hex(c.bg),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Nothing synced yet. Copy something on another device, or add one below.',
              textAlign: TextAlign.center,
              style: Ct.body(14, color: c.muted),
            ),
          ],
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
    final dev = item.device.isEmpty ? '' : '${item.device} · ';
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      decoration: BoxDecoration(
        color: c.dialogBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: c.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Text('TEXT', style: Ct.sectionLabel().copyWith(color: c.muted)),
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
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(18),
              child: SingleChildScrollView(
                child: SelectableText(
                  item.text,
                  style: Ct.body(16, color: c.ink, height: 1.55),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Material(
                  color: c.green,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.pop(context);
                      onCopy();
                    },
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.content_copy_outlined, size: 16,
                              color: c.isDark ? c.bg : Ck.bg),
                          const SizedBox(width: 9),
                          Text('Copy',
                              style: Ct.body(14, weight: FontWeight.w500,
                                  color: c.isDark ? c.bg : Ck.bg)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _SquareIconBtn(
                icon: Icons.delete_outline,
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
    const bg = Color(0xFF141310);
    const fg = Color(0xFFF4F1EA);
    const green = Color(0xFF8FBCA6);
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
                    icon: const Icon(Icons.close, color: fg),
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
                            style: Ct.mono(10.5, color: const Color(0xFF8A8471))),
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
                    child: Material(
                      color: green,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.pop(context);
                          onCopy();
                        },
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.content_copy_outlined,
                                  size: 16, color: bg),
                              const SizedBox(width: 9),
                              Text('Copy image',
                                  style: Ct.body(14,
                                      weight: FontWeight.w500, color: bg)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _SquareIconBtn(
                    icon: Icons.delete_outline,
                    color: const Color(0xFFC97B66),
                    border: const Color(0xFF4A2E26),
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
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Ink(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

// --- helpers ---

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

String _meta(HistoryItem item) {
  final rel = _rel(item.timestamp);
  final dev = item.device.isEmpty ? '' : '${item.device} · ';
  if (item.isImage) {
    final kb = ((item.imageBytes?.length ?? 0) / 1024).round();
    final fmt = item.mime.contains('png') ? 'PNG' : 'JPG';
    return '$fmt · $kb KB · $dev$rel';
  }
  return '$dev$rel';
}

String _dayLabel(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'TODAY';
  if (diff == 1) return 'YESTERDAY';
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];
  return '${months[t.month - 1]} ${t.day}';
}
