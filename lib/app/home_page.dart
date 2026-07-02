import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/history/history_item.dart';
import '../core/pairing/pairing_key.dart';
import 'clip_controller.dart';
import 'theme.dart';

/// The main Clippy screen: synced clipboard history (tap to copy), a manual
/// add box, and access to the pairing key for adding more devices.
class HomePage extends StatelessWidget {
  final ClipController controller;
  final PairingKey pairing;
  final Future<void> Function() onUnpair;

  const HomePage({
    super.key,
    required this.controller,
    required this.pairing,
    required this.onUnpair,
  });

  static void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text, style: Ct.body(13.5, color: Ck.bg)),
          backgroundColor: Ck.snack,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        ),
      );
  }

  void _showKey(BuildContext context) {
    final payload = pairing.toQrPayload();
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x731E1C15),
      builder: (context) => Dialog(
        backgroundColor: Ck.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add another device', style: Ct.title(24)),
              const SizedBox(height: 16),
              Text(
                'Scan this on your other device, or paste the key:',
                style: Ct.body(14, color: Ck.muted2),
              ),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Ck.border),
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
                  color: Ck.bg,
                  border: Border.all(color: Ck.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  payload,
                  style: Ct.mono(12, color: const Color(0xFF5C5748)),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: payload));
                    Navigator.pop(context);
                    _snack(context, 'Key copied');
                  },
                  child: Text(
                    'Copy key',
                    style: Ct.body(
                      14,
                      weight: FontWeight.w500,
                      color: Ck.green,
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
    return Scaffold(
      backgroundColor: Ck.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            if (!controller.ready) {
              return const Center(
                child: CircularProgressIndicator(color: Ck.green),
              );
            }
            final reconnecting = !controller.connected;
            return Column(
              children: [
                _TopBar(onDevices: () => _showKey(context), onUnpair: onUnpair),
                _StatusRow(
                  reconnecting: reconnecting,
                  isDesktop: controller.isDesktop,
                ),
                Container(height: 1, color: Ck.border),
                Expanded(
                  child: controller.history.isEmpty
                      ? const _EmptyState()
                      : _HistoryList(
                          items: controller.history,
                          onCopy: (item) async {
                            await controller.applyItem(item);
                            if (context.mounted) {
                              _snack(context, 'Copied to clipboard');
                            }
                          },
                        ),
                ),
                Container(height: 1, color: Ck.border),
                _AddBar(onAdd: controller.addManual, enabled: !reconnecting),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final VoidCallback onDevices;
  final Future<void> Function() onUnpair;
  const _TopBar({required this.onDevices, required this.onUnpair});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
      child: Row(
        children: [
          const ClippyMark(height: 24),
          const SizedBox(width: 11),
          Expanded(child: Text('Clippy', style: Ct.title(24))),
          IconButton(
            tooltip: 'Add another device',
            icon: const Icon(Icons.devices_outlined, color: Ck.ink, size: 21),
            onPressed: onDevices,
          ),
          IconButton(
            tooltip: 'Unpair this device',
            icon: const Icon(Icons.logout, color: Ck.ink, size: 21),
            onPressed: onUnpair,
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final bool reconnecting;
  final bool isDesktop;
  const _StatusRow({required this.reconnecting, required this.isDesktop});

  @override
  Widget build(BuildContext context) {
    final color = reconnecting ? Ck.rust : Ck.green;
    final text = reconnecting
        ? 'Reconnecting…'
        : isDesktop
        ? 'Auto-syncing — anything you copy here appears on your other devices.'
        : 'Synced — incoming clips land on your clipboard. Add one below to send.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 20, 14),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: Ct.body(13, color: reconnecting ? Ck.rust : Ck.muted2),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  final List<HistoryItem> items;
  final Future<void> Function(HistoryItem) onCopy;
  const _HistoryList({required this.items, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    // Build a flat list of section labels + cards, grouped by day.
    final children = <Widget>[];
    String? lastLabel;
    for (final item in items) {
      final label = _dayLabel(item.timestamp);
      if (label != lastLabel) {
        children.add(
          Padding(
            padding: EdgeInsets.only(
              top: lastLabel == null ? 2 : 12,
              bottom: 2,
            ),
            child: Text(label, style: Ct.sectionLabel()),
          ),
        );
        lastLabel = label;
      }
      children.add(_ClipCard(item: item, onCopy: () => onCopy(item)));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      itemCount: children.length,
      separatorBuilder: (_, i) =>
          SizedBox(height: children[i] is _ClipCard ? 10 : 0),
      itemBuilder: (_, i) => children[i],
    );
  }
}

class _ClipCard extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onCopy;
  const _ClipCard({required this.item, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Ck.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onCopy,
        child: Ink(
          decoration: BoxDecoration(
            border: Border.all(color: Ck.border),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _looksLikeCode(item.text)
                          ? Ct.mono(14, color: Ck.ink, weight: FontWeight.w500)
                          : Ct.body(15, weight: FontWeight.w500, color: Ck.ink),
                    ),
                    const SizedBox(height: 5),
                    Text(_rel(item.timestamp), style: Ct.mono(11)),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Ck.border),
                ),
                child: const Icon(
                  Icons.content_copy_outlined,
                  size: 15,
                  color: Ck.green,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 52),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Opacity(
              opacity: 0.4,
              child: ClippyMark(
                height: 58,
                clipHex: '7A7466',
                eyeHex: '7A7466',
                eyeFill: 'F4F1EA',
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Nothing synced yet. Copy something on another device, or add one below.',
              textAlign: TextAlign.center,
              style: Ct.body(14, color: Ck.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddBar extends StatefulWidget {
  final Future<void> Function(String) onAdd;
  final bool enabled;
  const _AddBar({required this.onAdd, required this.enabled});

  @override
  State<_AddBar> createState() => _AddBarState();
}

class _AddBarState extends State<_AddBar> {
  final _controller = TextEditingController();

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await widget.onAdd(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Ck.surface,
                border: Border.all(color: Ck.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _controller,
                style: Ct.body(14, color: Ck.ink),
                cursorColor: Ck.green,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  border: InputBorder.none,
                  hintText: 'Add a clip to sync…',
                  hintStyle: Ct.body(14, color: Ck.muted),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Opacity(
            opacity: widget.enabled ? 1 : 0.45,
            child: Material(
              color: Ck.green,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: widget.enabled ? _submit : null,
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  alignment: Alignment.center,
                  child: Text(
                    'Send',
                    style: Ct.body(14, weight: FontWeight.w500, color: Ck.bg),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
