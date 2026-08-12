import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../platform/share_channel.dart';
import 'permission_help_sheet.dart';
import 'theme.dart';
import 'theme_controller.dart';
import 'update_controller.dart';
import 'update_sheet.dart';

/// Settings: appearance (Light / Dark / System), background sync on Android,
/// about, and the group actions.
///
/// Redesigned from a stack of identical icon-text rows into designed groups:
/// the theme choice is a segmented control (three peers, one glance), every
/// action row leads with a [GlyphPlate], and background-sync setup reads as
/// the SEQUENCE it is — numbered steps under a progress track, built from a
/// list so the next step slots in without another redesign.
class SettingsPage extends StatelessWidget {
  final ThemeController theme;
  final VoidCallback onAddDevice;
  final Future<void> Function() onUnpair;

  const SettingsPage({
    super.key,
    required this.theme,
    required this.onAddDevice,
    required this.onUnpair,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // Extra top padding on macOS so the back arrow + title clear
              // the floating traffic-light window buttons.
              padding: EdgeInsets.fromLTRB(
                8,
                defaultTargetPlatform == TargetPlatform.macOS ? 34 : 10,
                20,
                10,
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded,
                        color: c.ink, size: ClipIcons.nav),
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Text('Settings', style: Ct.title(24, color: c.ink)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                children: [
                  _Label('APPEARANCE', c),
                  ValueListenableBuilder<ThemeMode>(
                    valueListenable: theme,
                    builder: (context, mode, _) => ClipCard(
                      padding: const EdgeInsets.all(6),
                      child: Row(
                        children: [
                          _ThemeSeg(
                            icon: Icons.light_mode_rounded,
                            label: 'Light',
                            selected: mode == ThemeMode.light,
                            onTap: () => theme.set(ThemeMode.light),
                          ),
                          _ThemeSeg(
                            icon: Icons.dark_mode_rounded,
                            label: 'Dark',
                            selected: mode == ThemeMode.dark,
                            onTap: () => theme.set(ThemeMode.dark),
                          ),
                          _ThemeSeg(
                            icon: Icons.brightness_auto_rounded,
                            label: 'System',
                            selected: mode == ThemeMode.system,
                            onTap: () => theme.set(ThemeMode.system),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _Note("System follows your device's appearance "
                      'automatically.', c),
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    const SizedBox(height: 26),
                    _Label('BACKGROUND SYNC', c),
                    const _BgSyncCard(),
                    _Note(
                        'Lets copies sync while Clippy is closed. Android only '
                        'allows this via an accessibility service; reading the '
                        'clipboard briefly flickers the screen. Allowing '
                        'background battery use keeps the connection alive '
                        'while the screen is off — without it Android pauses '
                        'sync minutes after the phone locks. Off by default.',
                        c),
                  ],
                  const SizedBox(height: 26),
                  _Label('ABOUT', c),
                  ClipCard(
                    child: Column(
                      children: [
                        const _VersionRow(),
                        _Divider(c),
                        _ActionRow(
                          c,
                          icon: Icons.download_rounded,
                          base: scheme.primary,
                          label: 'Check for updates',
                          labelColor: c.ink,
                          trailing: Icon(Icons.chevron_right_rounded,
                              size: ClipIcons.row, color: c.muted),
                          onTap: () => _checkForUpdates(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  _Label('GROUP', c),
                  ClipCard(
                    child: Column(
                      children: [
                        _ActionRow(
                          c,
                          icon: Icons.devices_rounded,
                          base: scheme.primary,
                          label: 'Add another device',
                          labelColor: c.ink,
                          trailing: Icon(Icons.chevron_right_rounded,
                              size: ClipIcons.row, color: c.muted),
                          onTap: onAddDevice,
                        ),
                        _Divider(c),
                        _ActionRow(
                          c,
                          icon: Icons.logout_rounded,
                          base: scheme.error,
                          label: 'Unpair this device',
                          labelColor: c.rust,
                          onTap: () async {
                            Navigator.of(context).pop();
                            await onUnpair();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await updater.checkNow();
    if (!context.mounted) return;
    switch (result) {
      case CheckResultUpdateAvailable():
        final info = updater.available.value;
        if (info != null) await showUpdateSheet(context, info);
      case CheckResultUpToDate():
        messenger.showSnackBar(
          const SnackBar(content: Text("You're on the latest version.")),
        );
      case CheckResultFailed(:final message):
        messenger.showSnackBar(
          SnackBar(content: Text("Couldn't check for updates: $message")),
        );
    }
  }
}

class _Label extends StatelessWidget {
  final String text;
  final ClippyColors c;
  const _Label(this.text, this.c);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(text, style: Ct.sectionLabel(color: c.muted)),
      );
}

/// The explanatory sentence under a card group. Its own widget so every note
/// in the screen keeps one indent and one colour.
class _Note extends StatelessWidget {
  final String text;
  final ClippyColors c;
  const _Note(this.text, this.c);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
        child: Text(text, style: Ct.body(12.5, color: c.muted)),
      );
}

class _Divider extends StatelessWidget {
  final ClippyColors c;
  const _Divider(this.c);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 66),
        child: Container(height: 1, color: c.border.withValues(alpha: 0.55)),
      );
}

/// One cell of the appearance control. A theme choice is one pick from three
/// visible peers — a segmented control shows all three states in one glance,
/// where the old three radio rows spent a whole card saying the same thing.
class _ThemeSeg extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeSeg({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? c.selBg : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? scheme.primary.withValues(alpha: c.isDark ? 0.55 : 0.45)
                    : Colors.transparent,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: ClipIcons.row,
                    color: selected ? c.accent : c.muted2),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: Ct.body(12.5,
                      weight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? c.accent : c.muted2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final ClippyColors c;
  final IconData icon;

  /// The plate's identity colour — a scheme role, per [GlyphPlate].
  final Color base;
  final String label;
  final Color labelColor;
  final Widget? trailing;
  final VoidCallback onTap;
  const _ActionRow(
    this.c, {
    required this.icon,
    required this.base,
    required this.label,
    required this.labelColor,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            GlyphPlate(icon: icon, base: base, size: 36),
            const SizedBox(width: 14),
            Expanded(
                child: Text(label,
                    style: Ct.body(15,
                        weight: FontWeight.w500, color: labelColor))),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// The running app's version, shown in the About card. Loaded asynchronously
/// via package_info_plus — the same source the updater compares against.
class _VersionRow extends StatefulWidget {
  const _VersionRow();
  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          GlyphPlate(
              icon: Icons.info_rounded, base: scheme.tertiary, size: 36),
          const SizedBox(width: 14),
          Expanded(
              child: Text('Version',
                  style: Ct.body(15, weight: FontWeight.w500, color: c.ink))),
          // Tabular so the number does not shuffle when it changes.
          Text(_version, style: Ct.mono(13.5, color: c.muted)),
        ],
      ),
    );
  }
}

/// One step of background-sync setup. The card below renders a LIST of these,
/// so growing the sequence (a battery step is already on its way) means
/// appending one entry — the layout, numbering and progress track follow.
class _SyncStep {
  final IconData icon;

  /// The row label while the step is still to do (no number — the leading
  /// badge carries it).
  final String setupLabel;

  /// The row label once granted.
  final String doneLabel;
  final bool granted;

  /// Pre-flight explainer content for the permission sheet, or null to open
  /// the system surface directly.
  ///
  /// The sheet exists for ONE reason: Android hides Accessibility and
  /// display-over-apps behind the "restricted setting" gate for sideloaded
  /// apps, and dropping the user cold into Settings dead-ends there. A step
  /// with no such gate — the battery exemption opens a plain system dialog —
  /// gets no sheet, because an explainer in front of a working button is just
  /// a tap the user has to spend.
  final String? helpTitle;
  final String? helpBody;
  final Future<void> Function() openSettings;

  const _SyncStep({
    required this.icon,
    required this.setupLabel,
    required this.doneLabel,
    required this.granted,
    required this.openSettings,
    this.helpTitle,
    this.helpBody,
  });
}

/// Background clipboard-sync setup (AccessibilityService + overlay). A
/// sequence with visible progress: a summary header, one track segment per
/// step, then the numbered steps. Refreshes when the app resumes from system
/// settings.
class _BgSyncCard extends StatefulWidget {
  const _BgSyncCard();
  @override
  State<_BgSyncCard> createState() => _BgSyncCardState();
}

class _BgSyncCardState extends State<_BgSyncCard> with WidgetsBindingObserver {
  bool _enabled = false;
  bool _overlay = false;
  bool _battery = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshUntilSettled();
  }

  /// Android publishes an accessibility grant asynchronously: the service has
  /// to bind before AccessibilityManager reports it, which can land after we
  /// have already resumed from the Settings screen. Reading once on resume can
  /// therefore catch the OLD value, leaving the first step on "Enable Clippy
  /// sync" forever even though the grant succeeded — which reads to the user
  /// as "it didn't work". Re-read a few times and stop as soon as something
  /// changes.
  Future<void> _refreshUntilSettled() async {
    const backoff = [
      Duration.zero,
      Duration(milliseconds: 250),
      Duration(milliseconds: 600),
      Duration(milliseconds: 1500),
    ];
    for (final delay in backoff) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (!mounted) return;
      if (await _refresh()) return; // settled
    }
  }

  /// Returns true when the reported state differed from what is on screen.
  Future<bool> _refresh() async {
    final s = await ShareChannel.bgSyncStatus();
    if (!mounted) return false;
    if (s.enabled == _enabled &&
        s.overlay == _overlay &&
        s.battery == _battery) {
      return false;
    }
    setState(() {
      _enabled = s.enabled;
      _overlay = s.overlay;
      _battery = s.battery;
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    // THE list. A third step (battery) slots in as one more entry here plus
    // its status field above — nothing else in this card changes.
    final steps = [
      _SyncStep(
        icon: Icons.accessibility_new_rounded,
        setupLabel: 'Enable Clippy sync',
        doneLabel: 'Accessibility enabled',
        granted: _enabled,
        helpTitle: 'Enable background sync',
        helpBody: "Clippy reads new copies through Android's Accessibility "
            'service so it can sync while the app is closed.',
        openSettings: ShareChannel.openA11ySettings,
      ),
      _SyncStep(
        icon: Icons.layers_rounded,
        setupLabel: 'Allow display over apps',
        doneLabel: 'Overlay allowed',
        granted: _overlay,
        helpTitle: 'Allow display over apps',
        helpBody: 'Clippy briefly draws over the screen to read the clipboard '
            'the moment you copy — part of background sync.',
        openSettings: ShareChannel.requestOverlay,
      ),
      // Step 3 — the one background sync actually stands on. Without the
      // battery exemption Doze cuts the relay connection minutes after the
      // screen locks (a foreground service does NOT exempt the process from
      // Doze networking), and Android 12+ refuses to restart the service from
      // the background after an OEM kill. It used to be asked once ever, at
      // first launch, and never appeared on this screen — so a user who
      // followed every step here could still watch background sync die the
      // moment the phone went into a pocket. That is the reported bug.
      //
      // No explainer sheet: this opens a plain system dialog, with no
      // restricted-setting gate to walk anyone past.
      _SyncStep(
        icon: Icons.battery_saver_rounded,
        setupLabel: 'Allow background battery use',
        doneLabel: 'Background use allowed',
        granted: _battery,
        openSettings: ShareChannel.requestBatteryExemption,
      ),
    ];
    final done = steps.where((s) => s.granted).length;
    final all = done == steps.length;
    final left = steps.length - done;
    final summary = all
        ? 'On — syncing while Clippy is closed'
        : done == 0
            ? 'Off — ${steps.length} steps to set up'
            // "one more step" was correct only while there were two steps.
            : '$done of ${steps.length} done — $left more '
                '${left == 1 ? 'step' : 'steps'}';
    return ClipCard(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                GlyphPlate(
                  icon: all ? Icons.sync_rounded : Icons.sync_disabled_rounded,
                  base: scheme.primary,
                  size: 36,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Background sync',
                          style: Ct.body(15,
                              weight: FontWeight.w600, color: c.ink)),
                      const SizedBox(height: 2),
                      Text(summary,
                          style: Ct.body(12.5,
                              color: all ? c.accent : c.muted2)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The progress track: one segment per step. Setup IS a sequence;
          // the track says how far along it is before a single row is read.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                for (final step in steps) ...[
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      height: 4,
                      decoration: BoxDecoration(
                        color: step.granted
                            ? c.accent
                            : c.border.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  if (step != steps.last) const SizedBox(width: 4),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) _Divider(c),
            _StepRow(index: i + 1, step: steps[i]),
          ],
        ],
      ),
    );
  }
}

/// One row of the setup sequence: a numbered badge that becomes a filled tick
/// when its permission is granted, the step's label, and a disclosure. Tap on
/// a pending step runs the pre-flight explainer; tap on a granted one goes
/// straight to the system toggle (to switch it off again).
class _StepRow extends StatelessWidget {
  final int index;
  final _SyncStep step;
  const _StepRow({required this.index, required this.step});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return InkWell(
      onTap: () {
        final title = step.helpTitle;
        final body = step.helpBody;
        // Granted → straight to the system toggle (to switch it back off).
        // Pending with no explainer → straight to the system surface.
        if (step.granted || title == null || body == null) {
          step.openSettings();
          return;
        }
        showPermissionHelpSheet(
          context,
          title: title,
          whatFor: body,
          onOpenSettings: step.openSettings,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _StepBadge(index: index, granted: step.granted),
            const SizedBox(width: 14),
            Icon(step.icon,
                size: ClipIcons.row,
                color: step.granted ? c.accent : c.muted2),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                step.granted ? step.doneLabel : step.setupLabel,
                style: Ct.body(14.5,
                    weight: step.granted ? FontWeight.w600 : FontWeight.w400,
                    color: step.granted ? c.accent : c.ink),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: ClipIcons.row, color: c.muted),
          ],
        ),
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  final int index;
  final bool granted;
  const _StepBadge({required this.index, required this.granted});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    // Filled brand chip when done — same fill as the filled buttons, because
    // `accent` is the lighter INK violet in dark mode and a white tick on it
    // would sit near 2:1.
    final fill = c.isDark ? primaryFillDark : scheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: granted ? fill : Colors.transparent,
        border: granted ? null : Border.all(color: c.borderStrong, width: 1.5),
      ),
      child: granted
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : Text('$index',
              style: Ct.mono(11.5, color: c.muted2, weight: FontWeight.w600)),
    );
  }
}
