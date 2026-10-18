import 'package:flutter/material.dart';

import '../platform/haptics.dart';
import 'theme.dart';

/// A device that sent clips, with how many of the current history are its.
typedef DeviceCount = ({String name, int count});

/// The device filter: ONE button, whatever the number of devices. It names
/// the current choice ("All devices", "SM-S918B") and opens a list to pick
/// from. A chip per device stopped working past three or four devices: the
/// row scrolled off screen and hid most of them.
class DeviceFilterButton extends StatelessWidget {
  final List<DeviceCount> devices;
  final String? value; // null = every device
  final String thisDevice;
  final ValueChanged<String?> onChanged;
  const DeviceFilterButton({
    super.key,
    required this.devices,
    required this.value,
    required this.thisDevice,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final on = value != null;
    final glyph = on
        ? (deviceGlyph(value!) ?? Icons.devices_other_rounded)
        : Icons.devices_rounded;
    final label = value ?? 'All devices';
    return Row(
      children: [
        Flexible(
          child: Semantics(
            button: true,
            label: 'Showing clips from $label. Change device',
            excludeSemantics: true,
            child: TextButton(
              onPressed: () async {
                Haptics.tick();
                final picked = await showDeviceFilterSheet(
                  context,
                  devices: devices,
                  value: value,
                  thisDevice: thisDevice,
                );
                if (picked != null) onChanged(picked.device);
              },
              style: TextButton.styleFrom(
                backgroundColor: on ? c.surface : Colors.transparent,
                shape: StadiumBorder(
                  side: BorderSide(color: on ? c.ink : c.border, width: on ? 1.2 : 1),
                ),
                padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.padded,
                visualDensity: VisualDensity.compact,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    glyph,
                    size: 15,
                    color: on ? deviceTint(scheme, value!) : c.muted2,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ct.body(13, weight: FontWeight.w600, color: on ? c.ink : c.muted2),
                    ),
                  ),
                  if (!on) ...[
                    const SizedBox(width: 6),
                    Text('${devices.length}', style: Ct.body(13, color: c.muted)),
                  ],
                  const SizedBox(width: 2),
                  Icon(Icons.expand_more_rounded, size: 18, color: on ? c.ink : c.muted2),
                ],
              ),
            ),
          ),
        ),
        // A one-tap way back, so a filter is never a dead end.
        if (on)
          IconButton(
            tooltip: 'Show all devices',
            onPressed: () {
              Haptics.tick();
              onChanged(null);
            },
            icon: Icon(Icons.close_rounded, size: 18, color: c.muted2),
          ),
      ],
    );
  }
}

/// The pick, wrapped so "All devices" (null) differs from a dismissed sheet.
typedef DevicePick = ({String? device});

Future<DevicePick?> showDeviceFilterSheet(
  BuildContext context, {
  required List<DeviceCount> devices,
  required String? value,
  required String thisDevice,
}) {
  return showModalBottomSheet<DevicePick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _DeviceSheet(devices: devices, value: value, thisDevice: thisDevice),
  );
}

class _DeviceSheet extends StatefulWidget {
  final List<DeviceCount> devices;
  final String? value;
  final String thisDevice;
  const _DeviceSheet({required this.devices, required this.value, required this.thisDevice});

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  // Past this many devices the list gets a filter field.
  static const _searchFrom = 7;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final media = MediaQuery.of(context);
    final total = widget.devices.fold<int>(0, (n, d) => n + d.count);
    final q = _q.trim().toLowerCase();
    final shown = [
      for (final d in widget.devices)
        if (q.isEmpty || d.name.toLowerCase().contains(q)) d,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.75),
        decoration: BoxDecoration(
          color: c.dialogBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(12, 10, 12, 12 + media.padding.bottom),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetGrabber(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  child: Text('Show clips from', style: Ct.title(22, color: c.ink)),
                ),
                if (widget.devices.length >= _searchFrom)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    child: TextField(
                      autofocus: false,
                      onChanged: (v) => setState(() => _q = v),
                      style: Ct.body(15, color: c.ink),
                      decoration: InputDecoration(
                        hintText: 'Find a device',
                        prefixIcon: Icon(Icons.search_rounded, size: 20, color: c.muted2),
                        isDense: true,
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (q.isEmpty)
                        _DeviceRow(
                          glyph: Icons.devices_rounded,
                          name: 'All devices',
                          detail: '$total ${total == 1 ? 'clip' : 'clips'}',
                          selected: widget.value == null,
                          onTap: () => Navigator.pop(context, (device: null)),
                        ),
                      for (final d in shown)
                        _DeviceRow(
                          glyph: deviceGlyph(d.name) ?? Icons.devices_other_rounded,
                          tint: deviceTint(Theme.of(context).colorScheme, d.name),
                          name: d.name,
                          detail: [
                            if (d.name == widget.thisDevice) 'This device',
                            '${d.count} ${d.count == 1 ? 'clip' : 'clips'}',
                          ].join(' · '),
                          selected: widget.value == d.name,
                          onTap: () => Navigator.pop(context, (device: d.name)),
                        ),
                      if (shown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No device matches "$_q"',
                            textAlign: TextAlign.center,
                            style: Ct.body(14, color: c.muted2),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final IconData glyph;
  final Color? tint;
  final String name;
  final String detail;
  final bool selected;
  final VoidCallback onTap;
  const _DeviceRow({
    required this.glyph,
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Material(
      color: selected ? c.selBg : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(glyph, size: 20, color: tint ?? c.muted2),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ct.body(15.5, weight: FontWeight.w600, color: c.ink),
                      ),
                      Text(detail, style: Ct.body(13, color: c.muted2)),
                    ],
                  ),
                ),
                if (selected) Icon(Icons.check_rounded, size: 20, color: c.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
