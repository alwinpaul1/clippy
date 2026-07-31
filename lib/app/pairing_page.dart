import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/pairing/pairing_key.dart';
import 'qr_scanner_page.dart';
import 'theme.dart';

/// First-run pairing. One device creates a group key; other devices join by
/// scanning its QR or pasting the key.
class PairingPage extends StatefulWidget {
  final Future<void> Function(PairingKey) onPaired;
  const PairingPage({super.key, required this.onPaired});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _controller = TextEditingController();
  bool _busy = false;

  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  void _generate() => _controller.text = PairingKey.generate().toQrPayload();

  Future<void> _scan() async {
    final result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScannerPage()));
    if (result != null && mounted) _controller.text = result.trim();
  }

  Future<void> _pair() async {
    PairingKey key;
    try {
      key = PairingKey.fromQrPayload(_controller.text.trim());
    } catch (_) {
      final c = context.ck;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'That does not look like a valid key.',
            // The snack chip is dark in BOTH themes, so its label stays the
            // fixed light cream. Using c.bg here would be dark-on-dark in dark
            // mode — this is deliberately not migrated to the theme extension.
            style: Ct.body(13.5, color: Ck.bg),
          ),
          backgroundColor: c.snack,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    await widget.onPaired(key);
  }

  @override
  Widget build(BuildContext context) {
    final key = _controller.text.trim();
    final c = context.ck;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 36, 28, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      // Alive here too — same bob + blink as the home header.
                      child: AnimatedClippyMark(
                        height: 99,
                        clipHex: c.hex(c.green),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      'Pair your devices',
                      textAlign: TextAlign.center,
                      style: Ct.title(34, color: c.ink),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Generate a key on your first device, then paste or scan '
                      'it on the others. End-to-end encrypted — the server never '
                      'sees it.',
                      textAlign: TextAlign.center,
                      style: Ct.body(14.5, color: c.muted2, height: 1.5),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('GROUP KEY', style: Ct.sectionLabel()),
                        InkWell(
                          onTap: key.isEmpty
                              ? null
                              : () {
                                  Clipboard.setData(ClipboardData(text: key));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Key copied',
                                        // Dark chip in both themes — see _pair().
                                        style: Ct.body(13.5, color: Ck.bg),
                                      ),
                                      backgroundColor: c.snack,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  );
                                },
                          child: Icon(
                            Icons.content_copy_outlined,
                            size: 16,
                            color: key.isEmpty ? c.muted : c.green,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: c.surface,
                        border: Border.all(color: c.border),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 3,
                        style: Ct.mono(12.5, color: c.ink),
                        cursorColor: c.green,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                          hintText: 'paste key…',
                          // muted is only ~3:1 on the dark surface; muted2
                          // clears AA there. Light mode keeps muted as before.
                          hintStyle: Ct.mono(
                            12.5,
                            color: c.isDark ? c.muted2 : c.muted,
                          ),
                        ),
                      ),
                    ),
                    if (key.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            // Stays true white in both themes — a QR needs a
                            // real white quiet zone to scan reliably.
                            color: Colors.white,
                            border: Border.all(color: c.border),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: QrImageView(data: key, size: 180),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Scan this on your other device',
                        textAlign: TextAlign.center,
                        // Same reason as the key-field hint above.
                        style: Ct.body(
                          12.5,
                          color: c.isDark ? c.muted2 : c.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    _OutlinedAction(
                      icon: Icons.vpn_key_outlined,
                      label: 'Generate a new key',
                      onTap: _busy ? null : _generate,
                    ),
                    if (!_isDesktop) ...[
                      const SizedBox(height: 10),
                      _OutlinedAction(
                        icon: Icons.qr_code_scanner,
                        label: 'Scan QR code',
                        onTap: _busy ? null : _scan,
                      ),
                    ],
                    const SizedBox(height: 10),
                    _FilledAction(
                      label: 'Pair this device',
                      busy: _busy,
                      onTap: _busy ? null : _pair,
                    ),
                  ],
                ),
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

class _OutlinedAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _OutlinedAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Ink(
          height: 48,
          decoration: BoxDecoration(
            border: Border.all(color: c.borderStrong),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: c.green),
              const SizedBox(width: 10),
              Text(
                label,
                style: Ct.body(14, weight: FontWeight.w500, color: c.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilledAction extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback? onTap;
  const _FilledAction({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    // Dark mode's green is the *lighter* 0xFF8FBCA6, so the on-green
    // foreground has to flip to the dark background colour to stay legible.
    final onGreen = c.isDark ? c.bg : Ck.bg;
    return Material(
      color: c.green,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: busy
                ? SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: onGreen,
                    ),
                  )
                : Text(
                    label,
                    style: Ct.body(14, weight: FontWeight.w500, color: onGreen),
                  ),
          ),
        ),
      ),
    );
  }
}
