import 'package:flutter/material.dart';

import 'theme.dart';
import 'theme_controller.dart';

/// Settings (mockup turn 3c): appearance (Light / Dark / System) and group
/// actions (add another device, unpair). Theme-aware.
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
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 20, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back, color: c.ink, size: 22),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Text('Settings', style: Ct.title(24, color: c.ink)),
                ],
              ),
            ),
            Container(height: 1, color: c.border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _Label('APPEARANCE', c),
                  const SizedBox(height: 4),
                  ValueListenableBuilder<ThemeMode>(
                    valueListenable: theme,
                    builder: (context, mode, _) => _Card(
                      c,
                      children: [
                        _ThemeRow(
                          c,
                          icon: Icons.light_mode_outlined,
                          label: 'Light',
                          selected: mode == ThemeMode.light,
                          onTap: () => theme.set(ThemeMode.light),
                        ),
                        _Divider(c),
                        _ThemeRow(
                          c,
                          icon: Icons.dark_mode_outlined,
                          label: 'Dark',
                          selected: mode == ThemeMode.dark,
                          onTap: () => theme.set(ThemeMode.dark),
                        ),
                        _Divider(c),
                        _ThemeRow(
                          c,
                          icon: Icons.desktop_windows_outlined,
                          label: 'System',
                          selected: mode == ThemeMode.system,
                          onTap: () => theme.set(ThemeMode.system),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                    child: Text(
                      "System follows your device's appearance automatically.",
                      style: Ct.body(12, color: c.muted, height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _Label('GROUP', c),
                  const SizedBox(height: 4),
                  _Card(
                    c,
                    children: [
                      _ActionRow(
                        c,
                        icon: Icons.devices_outlined,
                        iconColor: c.muted2,
                        label: 'Add another device',
                        labelColor: c.ink,
                        trailing: Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: c.muted,
                        ),
                        onTap: onAddDevice,
                      ),
                      _Divider(c),
                      _ActionRow(
                        c,
                        icon: Icons.logout,
                        iconColor: c.rust,
                        label: 'Unpair this device',
                        labelColor: c.rust,
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
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  final ClippyColors c;
  const _Label(this.text, this.c);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 2),
    child: Text(
      text,
      style: Ct.sectionLabel().copyWith(color: c.muted),
    ),
  );
}

class _Card extends StatelessWidget {
  final ClippyColors c;
  final List<Widget> children;
  const _Card(this.c, {required this.children});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: c.surface,
      border: Border.all(color: c.border),
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
}

class _Divider extends StatelessWidget {
  final ClippyColors c;
  const _Divider(this.c);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(height: 1, color: c.border.withValues(alpha: 0.6)),
  );
}

class _ThemeRow extends StatelessWidget {
  final ClippyColors c;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeRow(
    this.c, {
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 19, color: c.muted2),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: Ct.body(15, color: c.ink))),
            _Radio(c, selected: selected),
          ],
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  final ClippyColors c;
  final bool selected;
  const _Radio(this.c, {required this.selected});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.surface,
        border: Border.all(
          color: selected ? c.green : c.borderStrong,
          width: selected ? 6 : 1.5,
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final ClippyColors c;
  final IconData icon;
  final Color iconColor;
  final String label;
  final Color labelColor;
  final Widget? trailing;
  final VoidCallback onTap;
  const _ActionRow(
    this.c, {
    required this.icon,
    required this.iconColor,
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 19, color: iconColor),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: Ct.body(15, color: labelColor))),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
