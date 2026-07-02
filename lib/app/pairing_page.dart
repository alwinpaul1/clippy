import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/pairing/pairing_key.dart';

/// First-run pairing. One device creates a group key; other devices join by
/// entering the same key. The key never touches the relay — it only groups your
/// devices and encrypts your clips.
class PairingPage extends StatefulWidget {
  final Future<void> Function(PairingKey) onPaired;
  const PairingPage({super.key, required this.onPaired});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _controller = TextEditingController();
  bool _busy = false;

  void _generate() {
    setState(() => _controller.text = PairingKey.generate().toQrPayload());
  }

  Future<void> _pair() async {
    final text = _controller.text.trim();
    PairingKey key;
    try {
      key = PairingKey.fromQrPayload(text);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That does not look like a valid key.')),
      );
      return;
    }
    setState(() => _busy = true);
    await widget.onPaired(key);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '📎',
                    style: TextStyle(fontSize: 56, color: scheme.primary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pair your devices',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'On your first device, generate a key. On every other device, '
                    'paste the same key. Your clipboard then syncs across them — '
                    'end-to-end encrypted, so the server never sees it.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    minLines: 2,
                    maxLines: 3,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: 'Group key',
                      suffixIcon: IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy),
                        onPressed: _controller.text.isEmpty
                            ? null
                            : () {
                                Clipboard.setData(
                                  ClipboardData(text: _controller.text),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Key copied')),
                                );
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: const Icon(Icons.vpn_key),
                    label: const Text('Generate a new key'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _pair,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Pair this device'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
