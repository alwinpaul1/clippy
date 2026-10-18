import 'package:flutter/material.dart';

import '../core/history/history_item.dart';
import '../core/signals/clip_signals.dart';
import 'signal_ui.dart';
import 'theme.dart';
import 'ui_kit.dart';

/// What a clip IS, for a row's mark and meta line. Four kinds only, the
/// distinctions a user acts on (open a link, run a command, view an image,
/// paste text). Finer taxonomy would be decoration.
enum ClipKind { text, link, code, image }

ClipKind clipKindOf(HistoryItem item) {
  if (item.isImage) return ClipKind.image;
  final t = item.text.trim();
  if (RegExp(r'^https?://\S+$').hasMatch(t) || RegExp(r'^www\.\S+$').hasMatch(t)) {
    return ClipKind.link;
  }
  if (_looksLikeCode(t)) return ClipKind.code;
  return ClipKind.text;
}

IconData clipKindGlyph(ClipKind kind) => switch (kind) {
      ClipKind.text => Icons.notes_rounded,
      ClipKind.link => Icons.link_rounded,
      ClipKind.code => Icons.terminal_rounded,
      ClipKind.image => Icons.image_rounded,
    };

String clipKindLabel(ClipKind kind) => switch (kind) {
      ClipKind.text => 'Text',
      ClipKind.link => 'Link',
      ClipKind.code => 'Code',
      ClipKind.image => 'Image',
    };

bool _looksLikeCode(String s) {
  final t = s.trim();
  if (t.length > 60 || t.contains('\n')) return false;
  return RegExp(r'^[\d\s]+$').hasMatch(t) ||
      RegExp(r'(sudo |docker |git |npm |cd |\$ |curl )').hasMatch(t);
}

String imageFormatLabel(HistoryItem item) {
  final m = item.mime.toLowerCase();
  if (m.contains('png')) return 'PNG';
  if (m.contains('gif')) return 'GIF';
  if (m.contains('webp')) return 'WEBP';
  return 'JPG';
}

/// Text clip preview: a bottom sheet with the full, selectable content, the
/// clip's actions, and Copy (primary) / Delete. A sensitive clip stays
/// blurred until "Show" is tapped: opening the sheet in a café should not
/// put a card number on screen.
class TextClipPreview extends StatefulWidget {
  final HistoryItem item;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;
  final List<ClipSignal> signals;
  final Duration? sensitiveLeft;
  final void Function(String text, String what) onCopyText;
  final void Function(Uri) onOpen;
  const TextClipPreview({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onDelete,
    required this.onTogglePin,
    this.signals = const [],
    this.sensitiveLeft,
    required this.onCopyText,
    required this.onOpen,
  });

  @override
  State<TextClipPreview> createState() => _TextClipPreviewState();
}

class _TextClipPreviewState extends State<TextClipPreview> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final item = widget.item;
    final kind = clipKindOf(item);
    final left = widget.sensitiveLeft;
    final sensitive = left != null;
    final meta = [
      signalMetaLabel(widget.signals) ?? clipKindLabel(kind),
      if (item.device.isNotEmpty) item.device,
      relativeAge(item.timestamp),
      if (!sensitive) '${item.text.length} chars',
    ].join(' · ');
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      decoration: BoxDecoration(
        color: c.dialogBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 18 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetGrabber(),
          Row(
            children: [
              Expanded(child: Text(meta.toUpperCase(), style: Ct.meta(color: c.muted))),
              if (sensitive)
                TextButton.icon(
                  onPressed: () => setState(() => _revealed = !_revealed),
                  icon: Icon(
                    _revealed ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                    size: 16,
                    color: c.ink,
                  ),
                  label: Text(_revealed ? 'Hide' : 'Show',
                      style: Ct.body(13.5, weight: FontWeight.w600, color: c.ink)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SingleChildScrollView(
                child: sensitive
                    ? SensitiveBody(
                        text: item.text,
                        signal: widget.signals.firstWhere((s) => s.isSensitive),
                        left: left,
                        revealed: _revealed,
                      )
                    : SelectableText(
                        item.text,
                        style: kind == ClipKind.code
                            ? Ct.mono(15, color: c.ink)
                            : Ct.body(16, color: c.ink, height: 1.55),
                      ),
              ),
            ),
          ),
          if (!sensitive && widget.signals.isNotEmpty) ...[
            const SizedBox(height: 8),
            SignalActions(
              signals: widget.signals,
              onCopyText: (t, w) {
                Navigator.pop(context);
                widget.onCopyText(t, w);
              },
              onOpen: widget.onOpen,
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onCopy();
                  },
                  icon: const Icon(Icons.copy_rounded, size: ClipIcons.inline),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 10),
              RoundIconButton(
                icon: item.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                tooltip: item.pinned ? 'Unpin' : 'Pin to the top',
                fill: Theme.of(context).colorScheme.surfaceContainerLow,
                onTap: () {
                  Navigator.pop(context);
                  widget.onTogglePin();
                },
              ),
              const SizedBox(width: 10),
              RoundIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Delete clip',
                color: c.rust,
                fill: c.rust.withValues(alpha: c.isDark ? 0.16 : 0.08),
                onTap: () {
                  Navigator.pop(context);
                  widget.onDelete();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Image clip preview: a full-screen viewer with Copy image / Delete. Fixed
/// dark chrome in BOTH themes, like the QR scanner: a viewer that repaints its
/// frame white washes out the picture it exists to show.
class ImageClipPreview extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;

  /// The text read from the image on this device, or null while it has not
  /// been read (or there is none). Offers "Copy text" when present.
  final String? imageText;
  final void Function(String text)? onCopyText;
  const ImageClipPreview({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onDelete,
    required this.onTogglePin,
    this.imageText,
    this.onCopyText,
  });

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFF3F2EE);
    const meta = Color(0xFF9A9893); // dark `outline`, 6.65:1 on scannerBg
    const danger = Color(0xFFFF8A7A); // dark `error`
    final kb = ((item.imageBytes?.length ?? 0) / 1024).round();
    final info = [
      imageFormatLabel(item),
      '$kb KB',
      if (item.device.isNotEmpty) item.device,
      relativeAge(item.timestamp),
    ].join(' · ');
    return Scaffold(
      backgroundColor: scannerBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded, color: fg),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(info.toUpperCase(),
                        overflow: TextOverflow.ellipsis,
                        style: Ct.meta(color: meta)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: item.imageBytes != null
                    ? InteractiveViewer(
                        minScale: 1,
                        maxScale: 6,
                        clipBehavior: Clip.none,
                        child: Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.memory(item.imageBytes!, fit: BoxFit.contain),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            if (imageText != null &&
                imageText!.trim().isNotEmpty &&
                onCopyText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: fg,
                      side: BorderSide(color: fg.withValues(alpha: 0.28)),
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      onCopyText!(imageText!.trim());
                    },
                    icon: const Icon(Icons.text_fields_rounded, size: ClipIcons.inline),
                    label: const Text('Copy text from image'),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + MediaQuery.of(context).padding.bottom),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      // The light-on-dark fill of the dark theme, fixed here
                      // because this screen is dark in both themes.
                      style: FilledButton.styleFrom(
                        backgroundColor: fg,
                        foregroundColor: const Color(0xFF161614),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        onCopy();
                      },
                      icon: const Icon(Icons.copy_rounded, size: ClipIcons.inline),
                      label: const Text('Copy image'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  RoundIconButton(
                    icon: item.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    tooltip: item.pinned ? 'Unpin' : 'Pin to the top',
                    color: fg,
                    fill: fg.withValues(alpha: 0.12),
                    onTap: () {
                      Navigator.pop(context);
                      onTogglePin();
                    },
                  ),
                  const SizedBox(width: 10),
                  RoundIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete clip',
                    color: danger,
                    fill: danger.withValues(alpha: 0.16),
                    onTap: () {
                      Navigator.pop(context);
                      onDelete();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
