import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/pairing/pairing_key.dart';
import 'clip_controller.dart';

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

  void _showKey(BuildContext context) {
    final payload = pairing.toQrPayload();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add another device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Paste this key into Clippy on your other device:'),
            const SizedBox(height: 12),
            SelectableText(payload,
                style: const TextStyle(fontFamily: 'monospace')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: payload));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Key copied')),
              );
            },
            child: const Text('Copy key'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        title: const Text('📎 Clippy'),
        actions: [
          IconButton(
            tooltip: 'Add another device',
            icon: const Icon(Icons.devices),
            onPressed: () => _showKey(context),
          ),
          IconButton(
            tooltip: 'Unpair this device',
            icon: const Icon(Icons.logout),
            onPressed: onUnpair,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.ready) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              _StatusBanner(
                  isDesktop: controller.isDesktop,
                  connected: controller.connected),
              const Divider(height: 1),
              Expanded(
                child: controller.history.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Nothing synced yet.\nCopy something on another '
                            'device, or add one below.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: controller.history.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final item = controller.history[i];
                          return ListTile(
                            leading: const Icon(Icons.content_paste),
                            title: Text(item.text,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: const Text('tap to copy'),
                            onTap: () async {
                              await controller.applyItem(item);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Copied to clipboard')),
                                );
                              }
                            },
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              _AddBar(onAdd: controller.addManual),
            ],
          );
        },
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final bool isDesktop;
  final bool connected;
  const _StatusBanner({required this.isDesktop, required this.connected});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reconnecting = !connected;
    return Container(
      width: double.infinity,
      color: reconnecting
          ? scheme.errorContainer
          : scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(reconnecting ? Icons.cloud_off : Icons.sync, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reconnecting
                  ? 'Reconnecting…'
                  : isDesktop
                      ? 'Auto-syncing — anything you copy here appears on your other devices.'
                      : 'Synced. Incoming clips land on your clipboard; add one below to send.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddBar extends StatefulWidget {
  final Future<void> Function(String) onAdd;
  const _AddBar({required this.onAdd});

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
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Add a clip to sync…',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _submit, child: const Text('Send')),
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
