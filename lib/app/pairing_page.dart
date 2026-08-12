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
/// This screen deliberately keeps its OLD layout — the owner reviewed the
/// redesigned version and asked for the previous structure back, with only
/// the colours updated ("revert this to old but keep the same colors like
/// new"). So: the loose ink mascot with no plate behind it, the old sizes and
/// spacing, the old bordered key field, and PLAIN outlined/filled action
/// buttons — the violet system paints them, but the bones are the originals.
/// The brand gradient does NOT appear here anymore; see docs/DESIGN.md.
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
  /// `snackBarTheme`, which uses the M3 inverse pair — so the label flips with
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
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  28,
                  // Clear the macOS traffic-light buttons: the title bar is
                  // transparent, so content underlaps them.
                  defaultTargetPlatform == TargetPlatform.macOS ? 44 : 36,
                  28,
                  32,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      // Alive here too — same bob + blink as the home header,
                      // and the same INK as the home header: the mascot is one
                      // face with one colour everywhere.
                      child: AnimatedClippyMark(
                        height: 99,
                        clipHex: c.hex(c.ink),
                        eyeHex: c.hex(c.ink),
                        eyeFill: c.hex(c.bg),
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
                        Text('GROUP KEY', style: Ct.sectionLabel(color: c.muted)),
                        InkWell(
                          onTap: key.isEmpty
                              ? null
                              : () {
                                  Clipboard.setData(ClipboardData(text: key));
                                  _toast('Key copied');
                                },
                          child: Icon(
                            Icons.copy_rounded,
                            size: ClipIcons.inline,
                            color: key.isEmpty ? c.muted : c.accent,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        // The old bordered field, painted with the card
                        // system's own tokens (surfaceContainerLowest fill,
                        // outlineVariant hairline) instead of bespoke values.
                        color: c.surface,
                        // borderStrong (M3 `outline`), not the decorative
                        // outlineVariant: this edge is the only boundary the
                        // text field has, so it owes 3:1 (WCAG 1.4.11).
                        border: Border.all(color: c.borderStrong),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 3,
                        style: Ct.mono(12.5, color: c.ink),
                        cursorColor: c.accent,
                        decoration: InputDecoration(
                          isDense: true,
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          hintText: 'paste key…',
                          // The violet palette's `muted` is `outline`, audited
                          // past 4.5:1 on every surface tier in both themes —
                          // the old per-theme hint branch is no longer needed.
                          hintStyle: Ct.mono(12.5, color: c.muted),
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
                        style: Ct.body(12.5, color: c.muted),
                      ),
                    ],
                    const SizedBox(height: 22),
                    _OutlinedAction(
                      icon: Icons.key_rounded,
                      label: 'Generate a new key',
                      onTap: _busy ? null : _generate,
                    ),
                    if (!_isDesktop) ...[
                      const SizedBox(height: 10),
                      _OutlinedAction(
                        icon: Icons.qr_code_scanner_rounded,
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
      clipBehavior: Clip.antiAlias,
      child: InkWell(
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
              Icon(icon, size: 17, color: c.accent),
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

/// The old PLAIN filled button, back at the owner's request — not the
/// gradient. New paint only: the fill is the theme's filled-button pair
/// (`primaryFillDark` in dark, `primary` in light) so white ink clears 4.5:1
/// in both themes.
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
    final scheme = Theme.of(context).colorScheme;
    final fill = c.isDark ? primaryFillDark : scheme.primary;
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
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
                      color: c.onBrand,
                    ),
                  )
                : Text(
                    label,
                    style:
                        Ct.body(14, weight: FontWeight.w500, color: c.onBrand),
                  ),
          ),
        ),
      ),
    );
  }
}
