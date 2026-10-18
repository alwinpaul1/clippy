import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/history/history_item.dart';
import '../core/pairing/pairing_key.dart';
import 'clip_controller.dart';
import 'theme.dart';
import 'ui_kit.dart';

/// Devices: this device with its live connection, and every other device that
/// has put a clip in the shared history, with when it last did. The relay has
/// no presence, so "last clip" is the honest signal; a device is never shown
/// as "online" on a guess. One primary action: add a device.
class DevicesPage extends StatelessWidget {
  final ClipController controller;
  final PairingKey pairing;
  const DevicesPage({super.key, required this.controller, required this.pairing});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final self = controller.deviceName;
            final others = _othersFrom(controller.history, self);
            return Column(
              children: [
                const PageHeader(title: 'Devices'),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                        children: [
                          const SectionLabel('This device',
                              padding: EdgeInsets.fromLTRB(4, 4, 4, 8)),
                          _DeviceCard(
                            name: self.isEmpty ? 'This device' : self,
                            detail: controller.connected ? 'Connected' : 'Reconnecting…',
                            detailColor: controller.connected ? c.syncOk : c.rust,
                          ),
                          if (others.isNotEmpty) ...[
                            const SectionLabel('Other devices'),
                            GroupCard(
                              dividerIndent: 70,
                              children: [
                                for (final d in others)
                                  _DeviceRow(
                                    name: d.name,
                                    detail: 'Last clip ${_ago(d.last)}'
                                        ' · ${d.count} ${d.count == 1 ? 'clip' : 'clips'}',
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 18),
                          Text(
                            'Devices appear here once they copy something. Every '
                            'device with your key shares one encrypted history.',
                            style: Ct.body(13, color: c.muted2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => showAddDeviceSheet(context, pairing),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add a device'),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// "now", "4 min ago", "2 h ago", then "Yesterday" / "Mon" / "Oct 9" as
  /// they are: "Mon ago" is not English.
  static String _ago(DateTime t) {
    final a = relativeAge(t);
    return (a.endsWith(' min') || a.endsWith(' h')) ? '$a ago' : a;
  }

  static List<({String name, DateTime last, int count})> _othersFrom(
    List<HistoryItem> items,
    String self,
  ) {
    final last = <String, DateTime>{};
    final count = <String, int>{};
    for (final i in items) {
      final d = i.device.trim();
      if (d.isEmpty || d == self) continue;
      count[d] = (count[d] ?? 0) + 1;
      final prev = last[d];
      if (prev == null || i.timestamp.isAfter(prev)) last[d] = i.timestamp;
    }
    final list = [
      for (final d in last.keys) (name: d, last: last[d]!, count: count[d]!),
    ]..sort((a, b) => b.last.compareTo(a.last));
    return list;
  }
}

class _DeviceCard extends StatelessWidget {
  final String name;
  final String detail;
  final Color detailColor;
  const _DeviceCard({required this.name, required this.detail, required this.detailColor});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final glyph = deviceGlyph(name);
    return ClipCard(
      radius: 20,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          GlyphPlate(
            icon: glyph,
            letter: glyph == null ? (name.isEmpty ? '?' : name[0].toUpperCase()) : null,
            base: deviceTint(scheme, name),
            size: 44,
            circle: true,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ct.body(16, weight: FontWeight.w600, color: c.ink)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: detailColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 7),
                    Text(detail, style: Ct.body(13, color: c.muted2)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final String name;
  final String detail;
  const _DeviceRow({required this.name, required this.detail});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    final glyph = deviceGlyph(name);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          GlyphPlate(
            icon: glyph,
            letter: glyph == null ? name[0].toUpperCase() : null,
            base: deviceTint(scheme, name),
            size: 40,
            circle: true,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ct.body(15, weight: FontWeight.w600, color: c.ink)),
                Text(detail, style: Ct.body(12.5, color: c.muted2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Add a device: the group key as a QR code (for a phone camera) or as text
/// (for a desktop without one), with the warning a key deserves. Shared by
/// the Devices screen, Settings and the empty state.
Future<void> showAddDeviceSheet(BuildContext context, PairingKey pairing) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddDeviceSheet(payload: pairing.toQrPayload()),
  );
}

enum _KeyView { qr, key }

class _AddDeviceSheet extends StatefulWidget {
  final String payload;
  const _AddDeviceSheet({required this.payload});

  @override
  State<_AddDeviceSheet> createState() => _AddDeviceSheetState();
}

class _AddDeviceSheetState extends State<_AddDeviceSheet> {
  _KeyView _view = _KeyView.qr;

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Container(
      decoration: BoxDecoration(
        color: c.dialogBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(22, 10, 22, 20 + MediaQuery.of(context).padding.bottom),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetGrabber(),
              Text('Add a device', style: Ct.title(22, color: c.ink)),
              const SizedBox(height: 6),
              Text(
                'Open Clippy on the other device and scan this code, or paste the key.',
                style: Ct.body(14, color: c.muted2),
              ),
              const SizedBox(height: 18),
              PillSegments<_KeyView>(
                expand: true,
                options: const [(_KeyView.qr, 'QR code'), (_KeyView.key, 'Key')],
                value: _view,
                onChanged: (v) => setState(() => _view = v),
              ),
              const SizedBox(height: 18),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _view == _KeyView.qr
                    ? Center(
                        key: const ValueKey('qr'),
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            // True white in both themes: a QR needs a real
                            // white quiet zone to scan reliably.
                            color: Colors.white,
                            border: Border.all(color: c.border),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: QrImageView(data: widget.payload, size: 196),
                        ),
                      )
                    : Container(
                        key: const ValueKey('key'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SelectableText(widget.payload,
                            style: Ct.mono(13, color: c.ink)),
                      ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: c.isDark ? 0.12 : 0.07),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.key_rounded, size: 17, color: c.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Treat this like a password. Anyone with it can read '
                        'everything you copy.',
                        style: Ct.body(13, color: c.ink),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.payload));
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Key copied')));
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
}
