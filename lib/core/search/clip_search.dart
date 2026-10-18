/// Ranked clip search, on-device, no model. Every word in the query must
/// match (AND), each one scored by how well it matched: a whole word beats the
/// start of a word, which beats a fragment, which beats a one-letter typo.
/// A few words also name a KIND of clip ("otp", "card", "phone"...), and match
/// any clip carrying that signal as well as clips that contain the word.
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
  const SearchDoc({
    required this.text,
    required this.device,
    required this.isImage,
    required this.signals,
    required this.timestamp,
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
  final text = doc.isImage ? '' : doc.text.toLowerCase();
  final words = _words(text);
  final device = doc.device.toLowerCase();
  final kinds = {for (final s in doc.signals) s.kind};

  var score = 0.0;
  for (final t in tokens) {
    var best = _matchText(t, text, words);
    if (device.contains(t)) best = best > 1.2 ? best : 1.2;
    if (doc.isImage && _imageWords.contains(t)) best = best > 3 ? best : 3;
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
