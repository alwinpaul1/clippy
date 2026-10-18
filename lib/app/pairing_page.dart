import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/pairing/pairing_key.dart';
import 'qr_scanner_page.dart';
import 'theme.dart';

/// First-run pairing. One device creates a group key; other devices join by
/// scanning its QR or pasting the key.
///
/// Redesigned 2026-10-18 at the owner's request (this screen used to keep its
/// old layout on purpose; that decision was reversed for the new design). One
/// card holds the key: paste it, scan it, or generate a new one, and once a
/// key is there its QR appears in the same card for the next device to scan.
/// One primary action below. References on Mobbin: Brave's sync-chain code
/// and Comet's add-device screen.
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

  /// One snackbar helper. The chip and its label both come from the theme's
  /// `snackBarTheme`, which uses the M3 inverse pair, so the label flips with
  /// the theme instead of being pinned to one palette's light colour.
  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pair() async {
    PairingKey key;
    try {
      key = PairingKey.fromQrPayload(_controller.text.trim());
    } catch (_) {
      _toast('That does not look like a valid key.');
      return;
    }
    setState(() => _busy = true);
    await widget.onPaired(key);
  }

  @override
  Widget build(BuildContext context) {
    final key = _controller.text.trim();
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  22,
                  // Clear the macOS traffic lights: the title bar is
                  // transparent, so content underlaps them.
                  defaultTargetPlatform == TargetPlatform.macOS ? 48 : 32,
                  22,
                  28,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: AnimatedClippyMark(
                        height: 76,
                        clipHex: c.hex(c.ink),
                        eyeHex: c.hex(c.ink),
                        eyeFill: c.hex(c.bg),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('Pair your devices',
                        textAlign: TextAlign.center, style: Ct.title(30, color: c.ink)),
                    const SizedBox(height: 8),
                    Text(
                      'Every device with the same key shares one clipboard. '
                      'Generate a key on your first device, then scan or paste '
                      'it on the others.',
                      textAlign: TextAlign.center,
                      style: Ct.body(14.5, color: c.muted2, height: 1.5),
                    ),
                    const SizedBox(height: 26),
                    ClipCard(
                      radius: 22,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                  child: Text('GROUP KEY', style: Ct.meta(color: c.muted))),
                              if (key.isNotEmpty)
                                Tooltip(
                                  message: 'Copy key',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      Clipboard.setData(ClipboardData(text: key));
                                      _toast('Key copied');
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(4),
                                      child: Icon(Icons.copy_rounded,
                                          size: ClipIcons.inline, color: c.ink),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 3,
                            style: Ct.mono(13, color: c.ink),
                            cursorColor: c.ink,
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: scheme.surfaceContainerLow,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: c.borderStrong),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                // borderStrong: this edge is the field's only
                                // boundary, so it owes 3:1 (WCAG 1.4.11).
                                borderSide: BorderSide(color: c.borderStrong),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: c.ink, width: 1.5),
                              ),
                              hintText: 'Paste a key',
                              hintStyle: Ct.mono(13, color: c.muted),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _SoftAction(
                                  icon: Icons.auto_awesome_rounded,
                                  label: 'New key',
                                  onTap: _busy ? null : _generate,
                                ),
                              ),
                              if (!_isDesktop) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _SoftAction(
                                    icon: Icons.qr_code_scanner_rounded,
                                    label: 'Scan QR code',
                                    onTap: _busy ? null : _scan,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: key.isEmpty
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    padding: const EdgeInsets.only(top: 18),
                                    child: Column(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(14),
                                          decoration: BoxDecoration(
                                            // True white in both themes: a QR
                                            // needs a real white quiet zone.
                                            color: Colors.white,
                                            border: Border.all(color: c.border),
                                            borderRadius: BorderRadius.circular(18),
                                          ),
                                          child: QrImageView(data: key, size: 176),
                                        ),
                                        const SizedBox(height: 10),
                                        Text('Scan this on your other device',
                                            textAlign: TextAlign.center,
                                            style: Ct.body(12.5, color: c.muted2)),
                                      ],
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _busy ? null : _pair,
                      child: _busy
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.2, color: scheme.onPrimary),
                            )
                          : const Text('Pair this device'),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_outline_rounded, size: 14, color: c.muted2),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'End-to-end encrypted. The relay never sees your key.',
                            textAlign: TextAlign.center,
                            style: Ct.body(12.5, color: c.muted2),
                          ),
                        ),
                      ],
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

/// A secondary action inside the key card: tonal, not outlined, so the one
/// filled button below stays the obvious next step.
class _SoftAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _SoftAction({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: c.ink),
              const SizedBox(width: 7),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: Ct.body(13.5, weight: FontWeight.w600, color: c.ink)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
