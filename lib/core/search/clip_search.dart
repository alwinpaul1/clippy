/// Ranked clip search, on-device, no model. Every word in the query must
/// match (AND), each one scored by how well it matched: a whole word beats the
/// start of a word, which beats a fragment, which beats a one-letter typo.
/// A few words also name a KIND of clip ("otp", "card", "phone"...), and match
/// any clip carrying that signal as well as clips that contain the word.
///
/// Image clips are searched by what they contain: the text in a screenshot
/// and the labels the OS classifier gave a photo (see image_index.dart).
///
/// Recency only breaks near-ties: a strong match from last week still beats a
/// weak one from a minute ago.
library;

import '../signals/clip_signals.dart';

/// Words that select a signal, as typed. "code" is deliberately included:
/// people search "code" when they want the OTP that just arrived.
const signalKeywords = <String, Set<SignalKind>>{
  'otp': {SignalKind.otp},
  'code': {SignalKind.otp},
  '2fa': {SignalKind.otp},
  'card': {SignalKind.card},
  'iban': {SignalKind.iban},
  'bank': {SignalKind.iban},
  'sensitive': {SignalKind.card, SignalKind.iban},
  'phone': {SignalKind.phone},
  'number': {SignalKind.phone},
  'email': {SignalKind.email},
  'mail': {SignalKind.email},
  'address': {SignalKind.address},
  'link': {SignalKind.url},
  'url': {SignalKind.url},
  'date': {SignalKind.date},
};

const _imageWords = {
  'image',
  'images',
  'photo',
  'picture',
  'screenshot',
  'png',
  'jpg',
};

/// The searchable view of one clip.
class SearchDoc {
  final String text;
  final String device;
  final bool isImage;
  final List<ClipSignal> signals;
  final DateTime timestamp;

  /// For an image: the text recognised in it, and its content labels.
  final String imageText;
  final List<String> imageLabels;
  const SearchDoc({
    required this.text,
    required this.device,
    required this.isImage,
    required this.signals,
    required this.timestamp,
    this.imageText = '',
    this.imageLabels = const [],
  });
}

List<String> queryTokens(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty)
    .toList();

/// The score of [doc] for [query], or null when it does not match. Higher is
/// better. An empty query matches everything with score 0.
double? scoreDoc(SearchDoc doc, String query, {DateTime? now}) {
  final tokens = queryTokens(query);
  if (tokens.isEmpty) return 0;
  final text = (doc.isImage ? doc.imageText : doc.text).toLowerCase();
  final words = _words(text);
  final device = doc.device.toLowerCase();
  final kinds = {for (final s in doc.signals) s.kind};

  var score = 0.0;
  for (final t in tokens) {
    var best = _matchText(t, text, words);
    if (device.contains(t)) best = best > 1.2 ? best : 1.2;
    if (doc.isImage && _imageWords.contains(t)) best = best > 3 ? best : 3;
    if (doc.isImage) {
      final l = _matchLabel(t, doc.imageLabels);
      if (l > best) best = l;
    }
    final want = signalKeywords[t];
    if (want != null && want.any(kinds.contains)) best = best > 3 ? best : 3;
    if (best == 0) return null; // every word must match
    score += best;
  }
  // The whole query as one phrase, in order: "track 7" beats a clip that has
  // "7" and "track" far apart.
  if (tokens.length > 1 && text.contains(tokens.join(' '))) score += 2;

  final age = (now ?? DateTime.now()).difference(doc.timestamp);
  score += 1 / (1 + age.inMinutes / (60 * 24)); // <= 1, halves after a day
  return score;
}

double _matchText(String t, String text, List<String> words) {
  if (text.isEmpty) return 0;
  if (words.contains(t)) return 3;
  if (words.any((w) => w.startsWith(t))) return 2;
  if (text.contains(t)) return 1.5;
  // Typo tolerance only for words long enough that one wrong letter is a
  // typo rather than a different word ("hauptbanhof" yes, "cat"→"car" no).
  if (t.length >= 4) {
    final allowed = t.length >= 8 ? 2 : 1;
    for (final w in words) {
      if ((w.length - t.length).abs() > allowed) continue;
      if (_withinEdits(t, w, allowed)) return 1;
    }
  }
  return 0;
}

/// A label is a word or two ("dog", "credit card"): a whole label word
/// counts nearly as much as a word in the text, the start of one a little
/// less. No fragments or typos, labels are too short for those to mean much.
double _matchLabel(String t, List<String> labels) {
  var best = 0.0;
  for (final label in labels) {
    for (final w in label.toLowerCase().split(' ')) {
      if (w == t || (t.endsWith('s') && w == t.substring(0, t.length - 1))) {
        return 2.5;
      }
      if (t.length >= 3 && w.startsWith(t)) best = 1.8;
    }
  }
  return best;
}

/// The line of an image's text that best shows why it matched [query], cut
/// to about [max] characters around the first hit; null when no line holds
/// any query word (it matched by label or kind instead).
String? imageTextSnippet(String imageText, String query, {int max = 80}) {
  final tokens = queryTokens(query);
  if (tokens.isEmpty || imageText.trim().isEmpty) return null;
  String? bestLine;
  var bestHits = 0;
  for (final raw in imageText.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final lower = line.toLowerCase();
    final hits = tokens.where(lower.contains).length;
    if (hits > bestHits) {
      bestHits = hits;
      bestLine = line;
    }
  }
  if (bestLine == null) return null;
  if (bestLine.length <= max) return bestLine;
  final at = bestLine.toLowerCase().indexOf(
    tokens.firstWhere(bestLine.toLowerCase().contains),
  );
  final start = (at - max ~/ 3).clamp(0, bestLine.length - max);
  final end = start + max;
  return '${start > 0 ? '…' : ''}${bestLine.substring(start, end).trim()}'
      '${end < bestLine.length ? '…' : ''}';
}

List<String> _words(String text) => text
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((w) => w.isNotEmpty)
    .toList();

/// Levenshtein distance <= [max], with an early exit per row.
bool _withinEdits(String a, String b, int max) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    var rowMin = cur[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final v = [
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return false;
    prev = cur;
  }
  return prev[b.length] <= max;
}
