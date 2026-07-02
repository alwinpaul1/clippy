import 'package:meta/meta.dart';

/// A change observed on the local system clipboard, reported by a platform's
/// ClipboardPort. `text` is null for non-text clipboard content.
@immutable
class ClipEvent {
  final String? text;
  final bool isConcealed;

  /// UTF-8 byte length of [text]; 0 when [text] is null.
  final int byteSize;

  const ClipEvent({this.text, this.isConcealed = false, this.byteSize = 0});

  bool get isText => text != null;
}
