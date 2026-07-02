/// The minimal clipboard-write capability HistoryStore needs for apply-on-tap.
/// The platform ClipboardPort (Plans 3–4) implements this.
abstract class ClipboardWriter {
  Future<void> setText(String text);
}
