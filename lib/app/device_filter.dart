import 'package:flutter/material.dart';

import '../platform/haptics.dart';
import 'theme.dart';

/// A device that sent clips, with how many of the current history are its.
typedef DeviceCount = ({String name, int count});

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

/// The device filter as it sits INSIDE the search bar: device glyph, a short
/// name and a chevron, 32 tall with a 48 tall hit area. Both controls narrow
/// the same list, so they share one field (as Evernote and Garmin place
/// their filter button at the search field's trailing edge). ONE chip for any
/// number of devices: a chip per device scrolled off screen past three or
/// four. It opens a sheet listing them all.
class DeviceFilterChip extends StatelessWidget {
  final List<DeviceCount> devices;
  final String? value; // null = every device
  final String thisDevice;
  final ValueChanged<String?> onChanged;
  const DeviceFilterChip({
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
    final label = value ?? 'All devices';
    return Semantics(
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
          backgroundColor: on ? scheme.primary : scheme.surfaceContainerLow,
          foregroundColor: on ? scheme.onPrimary : c.muted2,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.compact,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? (deviceGlyph(value!) ?? Icons.devices_other_rounded) : Icons.devices_rounded,
              size: 15,
              color: on ? scheme.onPrimary : c.muted2,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ct.body(
                  12.5,
                  weight: FontWeight.w600,
                  color: on ? scheme.onPrimary : c.muted2,
                ),
              ),
            ),
            Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: on ? scheme.onPrimary : c.muted2,
            ),
          ],
        ),
      ),
    );
  }
}
