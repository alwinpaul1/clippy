import 'package:flutter/material.dart';

import '../core/history/history_item.dart';
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

/// Text clip preview: a bottom sheet with the full, selectable content and
/// Copy (primary) / Delete.
class TextClipPreview extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  const TextClipPreview({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ck;
    final kind = clipKindOf(item);
    final meta = [
      clipKindLabel(kind),
      if (item.device.isNotEmpty) item.device,
      relativeAge(item.timestamp),
      '${item.text.length} chars',
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
          Text(meta.toUpperCase(), style: Ct.meta(color: c.muted)),
          const SizedBox(height: 12),
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  item.text,
                  style: kind == ClipKind.code
                      ? Ct.mono(15, color: c.ink)
                      : Ct.body(16, color: c.ink, height: 1.55),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    onCopy();
                  },
                  icon: const Icon(Icons.copy_rounded, size: ClipIcons.inline),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 10),
              RoundIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Delete clip',
                color: c.rust,
                fill: c.rust.withValues(alpha: c.isDark ? 0.16 : 0.08),
                onTap: () {
                  Navigator.pop(context);
                  onDelete();
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
  const ImageClipPreview({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onDelete,
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
