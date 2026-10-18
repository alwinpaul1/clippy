import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../core/history/history_item.dart';
import '../core/pairing/pairing_key.dart';
import '../platform/haptics.dart';
import '../platform/share_channel.dart';
import 'clip_controller.dart';
import 'clip_preview.dart';
import 'devices_page.dart';
import 'permission_help_sheet.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'theme_controller.dart';
import 'ui_kit.dart';
import 'update_card.dart';

/// The main screen: the shared clipboard as a feed.
///
/// Layout (2026-10 redesign, references on Mobbin: Perplexity's memories list
/// for the meta-over-body rows, Solflare / Arc Search for search + Today /
/// Yesterday sections): the mascot and wordmark, a sync pill, search, a kind
/// filter, then clips grouped by WHEN they were copied. The old screen grouped
/// by device; you look for a clip by when you copied it, and the device now
/// rides on every row's meta line instead.
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

  /// One snackbar for the whole screen; the theme's snackBarTheme styles it.
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
          onAddDevice: () => showAddDeviceSheet(context, pairing),
          onUnpair: onUnpair,
        ),
      ),
    );
  }

  void _openDevices(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DevicesPage(controller: controller, pairing: pairing),
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
              return Center(child: CircularProgressIndicator(color: c.ink));
            }
            return _HomeBody(
              controller: controller,
              onDevices: () => _openDevices(context),
              onAddDevice: () => showAddDeviceSheet(context, pairing),
              onSettings: () => _openSettings(context),
            );
          },
        ),
      ),
    );
  }
}

enum _Filter { all, text, links, images }

/// Stateful body: selection, search and filter survive history updates.
class _HomeBody extends StatefulWidget {
  final ClipController controller;
  final VoidCallback onDevices;
  final VoidCallback onAddDevice;
  final VoidCallback onSettings;
  const _HomeBody({
    required this.controller,
    required this.onDevices,
    required this.onAddDevice,
    required this.onSettings,
  });

  @override
  State<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends State<_HomeBody> {
  final Set<String> _selected = {};
  bool _selecting = false;
  _Filter _filter = _Filter.all;
  final _search = TextEditingController();
  String _query = '';
  // Ages ("4 min") are computed at build time; without a periodic rebuild they
  // go stale, and two devices show different ages for the same clip.
  Timer? _agesTicker;

  ClipController get _ctl => widget.controller;

  @override
  void initState() {
    super.initState();
    _agesTicker = Timer.periodic(
      const Duration(seconds: 30),
      (_) => mounted ? setState(() {}) : null,
    );
    _search.addListener(() {
      final q = _search.text.trim().toLowerCase();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void dispose() {
    _agesTicker?.cancel();
    _search.dispose();
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

  void _openPreview(HistoryItem item) {
    if (item.isImage && item.imageBytes != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ImageClipPreview(
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
        builder: (_) => TextClipPreview(
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
    final ok = await confirmDestructive(
      context,
      title:
          'Delete ${chosen.length} ${chosen.length == 1 ? 'clip' : 'clips'}?',
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
    final ok = await confirmDestructive(
      context,
      title: 'Clear all clips?',
      body:
          'This removes every clip from all your devices. Anything not saved '
          'elsewhere is gone for good.',
      action: 'Clear all',
    );
    if (ok == true) {
      Haptics.thump();
      await _ctl.clearAll();
    }
  }

  bool _matches(HistoryItem i) {
    final kind = clipKindOf(i);
    final kindOk = switch (_filter) {
      _Filter.all => true,
      _Filter.text => kind == ClipKind.text || kind == ClipKind.code,
      _Filter.links => kind == ClipKind.link,
      _Filter.images => kind == ClipKind.image,
    };
    if (!kindOk) return false;
    if (_query.isEmpty) return true;
    if (i.isImage) {
      return 'image'.contains(_query) ||
          i.device.toLowerCase().contains(_query);
    }
    return i.text.toLowerCase().contains(_query) ||
        i.device.toLowerCase().contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    final all = [..._ctl.history]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final live = all.map((i) => i.hash).toSet();
    _selected.retainAll(live);
    if (_selecting && _selected.isEmpty && all.isEmpty) _selecting = false;
    final shown = all.where(_matches).toList();
    final devices = {
      for (final i in all)
        if (i.device.trim().isNotEmpty) i.device.trim(),
      if (_ctl.deviceName.isNotEmpty) _ctl.deviceName,
    };
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;

    return Stack(
      children: [
        Column(
          children: [
            _Column(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _selecting
                    ? _SelectionBar(
                        key: const ValueKey('selection-bar'),
                        count: _selected.length,
                        topPad: isMac ? 28 : 0,
                        onClose: _exitSelection,
                        onSelectAll: () => _selectAll(shown),
                        onDelete: () => _deleteSelected(all),
                      )
                    : _Header(
                        key: const ValueKey('header'),
                        topPad: isMac ? 28 : 0,
                        connected: _ctl.connected,
                        deviceCount: devices.length,
                        onDevices: widget.onDevices,
                        onSettings: widget.onSettings,
                      ),
              ),
            ),
            if (all.isNotEmpty && !_selecting)
              _Column(
                child: _Toolbar(
                  search: _search,
                  filter: _filter,
                  onFilter: (f) => setState(() => _filter = f),
                  onClearAll: _clearAll,
                ),
              ),
            Expanded(
              child: all.isEmpty
                  ? _EmptyState(onAddDevice: widget.onAddDevice)
                  : shown.isEmpty
                  ? _NoMatches(query: _query)
                  : _Feed(
                      items: shown,
                      selecting: _selecting,
                      selected: _selected,
                      onCopy: _copy,
                      onDelete: _deleteOne,
                      onToggle: _toggle,
                      onLongPress: _enterSelection,
                      onPreview: _openPreview,
                    ),
            ),
          ],
        ),
        // Pinned banners. Only one shows at a time; the update banner sits in
        // the same slot and is the lowest priority.
        // Lifted above the floating update card when both show on a phone.
        ValueListenableBuilder<double>(
          valueListenable: UpdateCardHost.occupied,
          builder: (context, lift, child) => Positioned(
            left: 16,
            right: 16,
            bottom: 16 + lift,
            child: child!,
          ),
          child: SafeArea(child: _Column(child: _bannerFor(context))),
        ),
      ],
    );
  }

  Widget _bannerFor(BuildContext context) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    // Screenshot auto-sync can't work with "Select photos" (partial) or denied
    // photo access; a transient snackbar was too easy to miss.
    if (android &&
        (_ctl.screenshotAccess == 'partial' ||
            _ctl.screenshotAccess == 'denied')) {
      return _WarnBanner(
        icon: Icons.screenshot_monitor_rounded,
        message: "Screenshots won't sync. Clippy needs full photo access.",
        onFix: ShareChannel.openPhotoSettings,
      );
    }
    // Background sync was on and is now off, almost always because an app
    // update took the accessibility service with it.
    if (android && _ctl.bgSyncRegressed) {
      return _WarnBanner(
        icon: Icons.sync_problem_rounded,
        message: 'Background sync turned off. The last update reset it.',
        onFix: () => showPermissionHelpSheet(
          context,
          title: 'Enable background sync',
          whatFor:
              "Android switches this off whenever Clippy updates. Turn it "
              'back on and copies will sync again while the app is closed.',
          onOpenSettings: ShareChannel.openA11ySettings,
        ),
      );
    }
    // Updates are not here: UpdateCardHost floats its card above every
    // screen, so a warning above can no longer hide it.
    return const SizedBox.shrink();
  }
}

/// One reading column for everything on home: header, toolbar, feed and
/// banner share its edges, so on a wide desktop window they line up instead
/// of the chrome stretching while the clips stay centred.
const double _columnWidth = 720;

class _Column extends StatelessWidget {
  final Widget child;
  const _Column({required this.child});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _columnWidth),
      child: child,
    ),
  );
}

class _Header extends StatelessWidget {
  final double topPad;
  final bool connected;
  final int deviceCount;
  final VoidCallback onDevices;
  final VoidCallback onSettings;
  const _Header({
    super.key,
    required this.topPad,
    required this.connected,
    required this.deviceCount,
    required this.onDevices,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12 + topPad, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedClippyMark(
                height: 34,
                clipHex: c.hex(c.ink),
                eyeHex: c.hex(c.ink),
                eyeFill: c.hex(c.bg),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Clippy', style: Ct.wordmark(28, color: c.ink)),
              ),
              RoundIconButton(
                icon: Icons.devices_rounded,
                tooltip: 'Devices',
                onTap: onDevices,
              ),
              const SizedBox(width: 8),
              RoundIconButton(
                icon: Icons.settings_outlined,
                tooltip: 'Settings',
                onTap: onSettings,
              ),
            ],
          ),
          const SizedBox(height: 12),
          SyncStatusPill(connected: connected, deviceCount: deviceCount),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final TextEditingController search;
  final _Filter filter;
  final ValueChanged<_Filter> onFilter;
  final VoidCallback onClearAll;
  const _Toolbar({
    required this.search,
    required this.filter,
    required this.onFilter,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          TextField(
            controller: search,
            textInputAction: TextInputAction.search,
            style: Ct.body(15, color: c.ink),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search clips',
              hintStyle: Ct.body(15, color: c.muted),
              prefixIcon: Icon(Icons.search_rounded, size: 20, color: c.muted2),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: search,
                builder: (context, v, _) => v.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: c.muted2,
                        ),
                        onPressed: search.clear,
                      ),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              fillColor: c.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: c.isDark
                    ? BorderSide(color: c.border)
                    : BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: c.isDark
                    ? BorderSide(color: c.border)
                    : BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.ink, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: PillSegments<_Filter>(
                    options: const [
                      (_Filter.all, 'All'),
                      (_Filter.text, 'Text'),
                      (_Filter.links, 'Links'),
                      (_Filter.images, 'Images'),
                    ],
                    value: filter,
                    onChanged: (f) {
                      Haptics.tick();
                      onFilter(f);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onClearAll,
                // Quiet here; the confirm dialog carries the warning.
                style: TextButton.styleFrom(
                  foregroundColor: c.muted2,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(
                  'Clear all',
                  style: Ct.body(13, weight: FontWeight.w600, color: c.muted2),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Selection is a MODE: the header turns into an ink bar so the change of
/// behaviour is unmistakable, with the count in the signal orange.
class _SelectionBar extends StatelessWidget {
  final int count;
  final double topPad;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onDelete;
  const _SelectionBar({
    super.key,
    required this.count,
    required this.topPad,
    required this.onClose,
    required this.onSelectAll,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onInverseSurface;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 10 + topPad, 12, 6),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Leave selection',
              icon: Icon(Icons.close_rounded, color: fg, size: ClipIcons.nav),
              onPressed: onClose,
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$count',
                      style: Ct.title(
                        18,
                        color: context.ck.isDark
                            ? signalOrange
                            : signalOrangeBright,
                      ),
                    ),
                    TextSpan(
                      text: ' selected',
                      style: Ct.title(18, color: fg),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Select all',
              icon: Icon(
                Icons.done_all_rounded,
                color: fg,
                size: ClipIcons.nav,
              ),
              onPressed: onSelectAll,
            ),
            IconButton(
              tooltip: 'Delete selected',
              icon: Icon(
                Icons.delete_outline_rounded,
                color: fg,
                size: ClipIcons.nav,
              ),
              onPressed: count == 0 ? null : onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// The feed: Today / Yesterday / This week / Earlier, newest first. Capped at
/// a readable width so a wide desktop window doesn't stretch a line of text
/// across the whole screen.
class _Feed extends StatelessWidget {
  final List<HistoryItem> items;
  final bool selecting;
  final Set<String> selected;
  final Future<void> Function(HistoryItem) onCopy;
  final Future<void> Function(HistoryItem) onDelete;
  final void Function(HistoryItem) onToggle;
  final void Function(HistoryItem) onLongPress;
  final void Function(HistoryItem) onPreview;
  const _Feed({
    required this.items,
    required this.selecting,
    required this.selected,
    required this.onCopy,
    required this.onDelete,
    required this.onToggle,
    required this.onLongPress,
    required this.onPreview,
  });

  static String _bucket(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return 'This week';
    return 'Earlier';
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    String? current;
    for (final item in items) {
      final b = _bucket(item.timestamp);
      if (b != current) {
        rows.add(
          SectionLabel(
            b,
            padding: EdgeInsets.fromLTRB(4, current == null ? 12 : 20, 4, 8),
          ),
        );
        current = b;
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ClipRow(
            key: ValueKey(item.hash),
            item: item,
            selecting: selecting,
            selected: selected.contains(item.hash),
            onTap: () => selecting ? onToggle(item) : onPreview(item),
            onCopy: () => onCopy(item),
            onLongPress: () => onLongPress(item),
            onDelete: () => onDelete(item),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _columnWidth),
        // The floating update card covers the bottom on a phone; keep the
        // last clip scrollable clear of it.
        child: ValueListenableBuilder<double>(
          valueListenable: UpdateCardHost.occupied,
          builder: (context, lift, _) => ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              96 + lift + MediaQuery.of(context).padding.bottom,
            ),
            children: rows,
          ),
        ),
      ),
    );
  }
}

/// A clip as a card: the meta line on top (where it came from, when, what it
/// is), the content below at reading size, and the copy button in the
/// corner. Text clips show up to four lines; image clips show the picture.
class _ClipRow extends StatelessWidget {
  final HistoryItem item;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  const _ClipRow({
    super.key,
    required this.item,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onCopy,
    required this.onLongPress,
    required this.onDelete,
  });

  String _meta(ClipKind kind) {
    final parts = <String>[
      if (item.device.trim().isNotEmpty) item.device.trim(),
      relativeAge(item.timestamp),
    ];
    if (kind == ClipKind.image) {
      final kb = ((item.imageBytes?.length ?? 0) / 1024).round();
      parts.add('${imageFormatLabel(item)} $kb KB');
    } else if (kind != ClipKind.text) {
      parts.add(clipKindLabel(kind));
    }
    return parts.join(' · ').toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final kind = clipKindOf(item);
    final isImage = kind == ClipKind.image && item.imageBytes != null;
    final card = ClipCard(
      radius: 18,
      color: selected ? c.selBg : null,
      highlighted: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                deviceGlyph(item.device) ?? clipKindGlyph(kind),
                size: 14,
                color: deviceTint(scheme, item.device),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _meta(kind),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ct.meta(color: c.muted),
                ),
              ),
              if (selecting)
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: _Check(selected: selected),
                )
              else
                _CopyButton(onCopy: onCopy),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: isImage
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SizedBox(
                        width: double.infinity,
                        child: Image.memory(
                          item.imageBytes!,
                          fit: BoxFit.cover,
                          cacheWidth: 720,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  )
                : Text(
                    item.text.trim(),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: switch (kind) {
                      ClipKind.code => Ct.mono(14.5, color: c.ink),
                      // Ink with an underline, not a colour: orange is the
                      // signal and a red-orange link read as an error.
                      ClipKind.link =>
                        Ct.body(
                          15,
                          weight: FontWeight.w500,
                          color: c.ink,
                        ).copyWith(
                          decoration: TextDecoration.underline,
                          decorationColor: c.muted,
                          decorationThickness: 1.4,
                        ),
                      _ => Ct.body(15.5, color: c.ink, height: 1.45),
                    },
                  ),
          ),
        ],
      ),
    );

    if (selecting) return card;
    // Swipe left to delete. confirmDismiss triggers the delete and returns
    // false so the row isn't self-removed; the history rebuild removes it.
    return Dismissible(
      key: ValueKey('dismiss-${item.hash}'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.4},
      onUpdate: (d) {
        // Tick the instant the swipe crosses (or backs out of) the threshold.
        if (d.reached != d.previousReached) Haptics.tick();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        decoration: BoxDecoration(
          color: c.rust,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Icon(
          Icons.delete_outline_rounded,
          color: scheme.onError,
          size: 21,
        ),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: card,
    );
  }
}

/// Copy, confirmed in place: the icon flips to an orange tick for a moment,
/// because the copy itself is invisible and the button is the one place that
/// can say it happened. Motion budget: 180 ms, one icon.
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
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Copy',
      child: GestureDetector(
        onTap: _tap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _copied
                  ? c.accent.withValues(alpha: c.isDark ? 0.18 : 0.10)
                  : scheme.surfaceContainerLow,
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                key: ValueKey(_copied),
                size: 16,
                color: _copied ? c.accent : c.ink,
              ),
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // signalOrange carries a white tick at 5.18:1.
        color: selected ? signalOrange : Colors.transparent,
        border: Border.all(
          color: selected ? signalOrange : c.borderStrong,
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
          : null,
    );
  }
}

/// Empty history: the mascot waiting, one honest sentence, and the one action
/// that helps (an empty list usually means this is the only device).
class _EmptyState extends StatelessWidget {
  final VoidCallback onAddDevice;
  const _EmptyState({required this.onAddDevice});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedClippyMark(
                height: 72,
                clipHex: c.hex(c.muted),
                eyeHex: c.hex(c.muted),
                eyeFill: c.hex(c.bg),
              ),
              const SizedBox(height: 22),
              Text(
                'Nothing here yet',
                textAlign: TextAlign.center,
                style: Ct.title(22, color: c.ink),
              ),
              const SizedBox(height: 8),
              Text(
                'Copy something on any paired device and it lands here, ready '
                'to paste.',
                textAlign: TextAlign.center,
                style: Ct.body(14.5, color: c.muted2),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onAddDevice,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add a device'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  final String query;
  const _NoMatches({required this.query});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 0),
      child: Column(
        children: [
          Icon(Icons.search_off_rounded, size: 28, color: c.muted),
          const SizedBox(height: 10),
          Text(
            query.isEmpty ? 'No clips of this kind' : 'No clips match "$query"',
            textAlign: TextAlign.center,
            style: Ct.body(14.5, weight: FontWeight.w500, color: c.muted2),
          ),
        ],
      ),
    );
  }
}

/// The pinned-warning shape. The error tint carries the alarm; the surface
/// stays an ordinary card, because a fully red banner over the list reads as
/// a crash and neither warning is one.
class _WarnBanner extends StatelessWidget {
  final IconData icon;
  final String message;
  final VoidCallback onFix;
  const _WarnBanner({
    required this.icon,
    required this.message,
    required this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return ClipCard(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: c.rust),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: Ct.body(13, color: c.ink)),
          ),
          TextButton(
            onPressed: onFix,
            child: Text(
              'Fix',
              style: Ct.body(13.5, weight: FontWeight.w700, color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}
