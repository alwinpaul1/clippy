import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../platform/share_channel.dart';
import 'permission_help_sheet.dart';
import 'theme.dart';
import 'theme_controller.dart';
import 'ui_kit.dart';
import 'update_controller.dart';
import 'update_sheet.dart';

/// Settings: appearance, background sync (Android), devices, about, and the
/// one destructive action. Grouped inset cards with tracked section labels;
/// background-sync setup reads as a checklist (Mobbin reference: Crouton's
/// sync status), because setup IS a sequence of things to tick off.
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
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PageHeader(title: 'Settings'),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                    children: [
                      const SectionLabel('Appearance',
                          padding: EdgeInsets.fromLTRB(4, 4, 4, 8)),
                      ValueListenableBuilder<ThemeMode>(
                        valueListenable: theme,
                        builder: (context, mode, _) => PillSegments<ThemeMode>(
                          expand: true,
                          options: const [
                            (ThemeMode.light, 'Light'),
                            (ThemeMode.dark, 'Dark'),
                            (ThemeMode.system, 'System'),
                          ],
                          value: mode,
                          onChanged: theme.set,
                        ),
                      ),
                      if (defaultTargetPlatform == TargetPlatform.android) ...[
                        const SectionLabel('Background sync'),
                        const _BgSyncCard(),
                      ],
                      const SectionLabel('Devices'),
                      GroupCard(
                        children: [
                          _Row(
                            icon: Icons.add_rounded,
                            label: 'Add another device',
                            onTap: onAddDevice,
                          ),
                        ],
                      ),
                      const SectionLabel('About'),
                      GroupCard(
                        children: [
                          const _VersionRow(),
                          _Row(
                            icon: Icons.system_update_alt_rounded,
                            label: 'Check for updates',
                            onTap: () => _checkForUpdates(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      GroupCard(
                        children: [
                          _Row(
                            icon: Icons.logout_rounded,
                            label: 'Unpair this device',
                            danger: true,
                            showChevron: false,
                            onTap: () async {
                              Navigator.of(context).pop();
                              await onUnpair();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
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

/// A settings row: a plain glyph (no plate; the grouped card already frames
/// it), the label, and a chevron when it leads somewhere.
class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool showChevron;
  const _Row({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.showChevron = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final tone = danger ? c.rust : c.ink;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 21, color: tone),
            const SizedBox(width: 23),
            Expanded(
              child: Text(label,
                  style: Ct.body(15, weight: FontWeight.w500, color: tone)),
            ),
            if (showChevron)
              Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
          ],
        ),
      ),
    );
  }
}

/// The running app's version, from package_info_plus, the same source the
/// updater compares against.
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 21, color: c.ink),
          const SizedBox(width: 23),
          Expanded(
            child: Text('Version',
                style: Ct.body(15, weight: FontWeight.w500, color: c.ink)),
          ),
          // Tabular so the number does not shuffle when it changes.
          Text(_version, style: Ct.mono(13.5, color: c.muted2)),
        ],
      ),
    );
  }
}

/// One step of background-sync setup. The card below renders a LIST of these,
/// so growing the sequence (a battery step is already on its way) means
/// appending one entry, the layout, numbering and progress track follow.
class _SyncStep {
  final IconData icon;

  /// The row label while the step is still to do (no number, the leading
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
  /// with no such gate, the battery exemption opens a plain system dialog,
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
  /// sync" forever even though the grant succeeded, which reads to the user
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
    // its status field above, nothing else in this card changes.
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
            'the moment you copy. That is part of background sync.',
        openSettings: ShareChannel.requestOverlay,
      ),
      // Step 3, the one background sync actually stands on. Without the
      // battery exemption Doze cuts the relay connection minutes after the
      // screen locks (a foreground service does NOT exempt the process from
      // Doze networking), and Android 12+ refuses to restart the service from
      // the background after an OEM kill. It used to be asked once ever, at
      // first launch, and never appeared on this screen, so a user who
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
        ? 'On, syncing while Clippy is closed'
        : done == 0
            ? 'Off. ${steps.length} steps to set up'
            // "one more step" was correct only while there were two steps.
            : '$done of ${steps.length} done, $left more '
                '${left == 1 ? 'step' : 'steps'}';
    return ClipCard(
      radius: 20,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
            child: Row(
              children: [
                Icon(all ? Icons.sync_rounded : Icons.sync_disabled_rounded,
                    size: 21, color: all ? c.syncOk : c.ink),
                const SizedBox(width: 23),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Background sync',
                          style: Ct.body(15, weight: FontWeight.w600, color: c.ink)),
                      const SizedBox(height: 2),
                      Text(summary,
                          style: Ct.body(12.5, color: all ? c.syncOk : c.muted2)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The progress track: one segment per step, green as each is
          // granted. Setup IS a sequence; the track says how far along it is
          // before a single row is read.
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
            child: Row(
              children: [
                for (final step in steps) ...[
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      height: 4,
                      decoration: BoxDecoration(
                        color: step.granted ? c.syncOk : scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  if (step != steps.last) const SizedBox(width: 4),
                ],
              ],
            ),
          ),
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, indent: 62, color: c.border),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            _StepBadge(index: index, granted: step.granted),
            const SizedBox(width: 20),
            Expanded(
              child: Text(
                step.granted ? step.doneLabel : step.setupLabel,
                style: Ct.body(14.5,
                    weight: step.granted ? FontWeight.w500 : FontWeight.w600,
                    color: step.granted ? c.muted2 : c.ink),
              ),
            ),
            Icon(step.icon, size: 18, color: c.muted),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
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
    // Green when granted: this is a state light, like the sync pill.
    final fill = c.syncOk;
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
          ? Icon(Icons.check_rounded, size: 15, color: scheme.surface)
          : Text('$index',
              style: Ct.mono(11.5, color: c.muted2, weight: FontWeight.w600)),
    );
  }
}
