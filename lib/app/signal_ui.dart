import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/signals/clip_signals.dart';
import '../platform/link_opener.dart';
import 'theme.dart';

/// The meta-line word for a clip's leading signal ("CODE", "CARD"...), or
/// null to fall back to the clip's kind.
String? signalMetaLabel(List<ClipSignal> signals) {
  for (final s in signals) {
    switch (s.kind) {
      case SignalKind.otp:
        return 'Code';
      case SignalKind.card:
        return 'Card';
      case SignalKind.iban:
        return 'IBAN';
      default:
        break;
    }
  }
  return null;
}

/// "Clears in 4 min", counting down; the last minute reads "in under a
/// minute" rather than a ticking seconds count nobody needs.
String clearsInLabel(Duration left) {
  if (left <= Duration.zero) return 'Clearing…';
  if (left.inMinutes < 1) return 'Clears in under a minute';
  return 'Clears in ${left.inMinutes + (left.inSeconds % 60 > 0 ? 1 : 0)} min';
}

/// The one-tap actions a clip's signals offer, at most three, most useful
/// first: copy just the code, open the link, call, email, map. Each chip is a
/// full 48dp touch target even though it draws 36dp tall.
class SignalActions extends StatelessWidget {
  final List<ClipSignal> signals;
  final void Function(String text, String what) onCopyText;
  final void Function(Uri uri) onOpen;
  const SignalActions({
    super.key,
    required this.signals,
    required this.onCopyText,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    for (final s in signals) {
      if (chips.length == 3) break;
      final chip = _chipFor(context, s);
      if (chip != null) chips.add(chip);
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, children: chips);
  }

  Widget? _chipFor(BuildContext context, ClipSignal s) {
    switch (s.kind) {
      case SignalKind.otp:
        final code = otpDigits(s);
        return _Chip(
          icon: Icons.copy_rounded,
          label: 'Copy $code',
          emphasised: true,
          onTap: () => onCopyText(code, 'Code copied'),
        );
      case SignalKind.url:
      case SignalKind.phone:
      case SignalKind.email:
      case SignalKind.address:
        final uri = LinkOpener.uriFor(s);
        if (uri == null) return null;
        final (icon, label) = switch (s.kind) {
          SignalKind.url => (Icons.open_in_new_rounded, 'Open'),
          SignalKind.phone => (Icons.call_rounded, 'Call'),
          SignalKind.email => (Icons.mail_outline_rounded, 'Email'),
          _ => (Icons.map_outlined, 'Map'),
        };
        return _Chip(icon: icon, label: label, onTap: () => onOpen(uri));
      default:
        return null; // dates and sensitive values have no action
    }
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool emphasised;
  final VoidCallback onTap;
  const _Chip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final scheme = Theme.of(context).colorScheme;
    // The OTP is the clip's whole point, so it alone takes the signal tint.
    final fg = emphasised ? c.accent : c.ink;
    final bg = emphasised
        ? c.accent.withValues(alpha: c.isDark ? 0.16 : 0.09)
        : scheme.surfaceContainerLow;
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: fg),
      label: Text(
        label,
        style: Ct.body(13.5, weight: FontWeight.w600, color: fg),
      ),
      style: TextButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.padded, // 48dp hit area
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// A sensitive clip's body: the real text blurred past reading, with the
/// masked value ("•••• 4242") and the countdown on top. Screen readers get
/// the masked value only, never the number.
class SensitiveBody extends StatelessWidget {
  final String text;
  final ClipSignal signal;
  final Duration left;
  final bool revealed;
  const SensitiveBody({
    super.key,
    required this.text,
    required this.signal,
    required this.left,
    this.revealed = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final what = signal.kind == SignalKind.card ? 'Card number' : 'IBAN';
    final body = Text(
      text.trim(),
      maxLines: revealed ? null : 2,
      overflow: revealed ? null : TextOverflow.clip,
      style: Ct.mono(15, color: c.ink),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: '$what ${maskSensitive(signal)}, hidden',
          excludeSemantics: !revealed,
          child: revealed
              ? SelectableText(text, style: Ct.mono(15, color: c.ink))
              // The masked value reads as the clip; the blurred original
              // beneath says "there is more here, hidden" without showing it.
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lock_rounded, size: 16, color: c.muted2),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '$what ${maskSensitive(signal)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Ct.body(
                              15.5,
                              weight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRect(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                        child: body,
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.timer_outlined, size: 14, color: c.muted),
            const SizedBox(width: 6),
            Text(clearsInLabel(left), style: Ct.body(12.5, color: c.muted2)),
          ],
        ),
      ],
    );
  }
}
