/// On-device "signals" in a text clip: what it contains that a user can act
/// on (an OTP to copy, a number to call, an address to map) or should be
/// protected from (a card number, an IBAN). Pure Dart, no I/O, no model: every
/// detector is a pattern plus, where one exists, the format's own checksum, so
/// a random 16-digit order number is not mistaken for a card.
library;

enum SignalKind { otp, card, iban, phone, email, url, address, date }

class ClipSignal {
  final SignalKind kind;

  /// The matched text, as it appears in the clip.
  final String value;

  const ClipSignal(this.kind, this.value);

  /// Card numbers and IBANs: blurred in the list and auto-cleared.
  bool get isSensitive => kind == SignalKind.card || kind == SignalKind.iban;

  @override
  bool operator ==(Object other) =>
      other is ClipSignal && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => '${kind.name}($value)';
}

/// Clips longer than this are documents, not codes or cards; skipping them
/// keeps detection cheap on a pasted log file.
const _maxScanLength = 4000;

/// Signals in [text], most actionable first, at most one per value.
List<ClipSignal> detectSignals(String text) {
  if (text.isEmpty || text.length > _maxScanLength) return const [];
  final out = <ClipSignal>[];
  final taken = <(int, int)>[]; // spans already claimed by a stronger signal

  bool free(int s, int e) => taken.every((t) => e <= t.$1 || s >= t.$2);
  void add(SignalKind k, int s, int e) {
    if (!free(s, e)) return;
    taken.add((s, e));
    final v = text.substring(s, e).trim();
    if (!out.contains(ClipSignal(k, v))) out.add(ClipSignal(k, v));
  }

  // Order matters: a URL can contain digits that look like a phone number, a
  // card number contains an OTP-length run, an IBAN contains both.
  for (final m in _url.allMatches(text)) {
    var e = m.end;
    while (e > m.start && '.,;:!?)]}\'"'.contains(text[e - 1])) {
      e--;
    }
    add(SignalKind.url, m.start, e);
  }
  for (final m in _email.allMatches(text)) {
    add(SignalKind.email, m.start, m.end);
  }
  for (final m in _ibanPattern.allMatches(text)) {
    if (isValidIban(m.group(0)!)) add(SignalKind.iban, m.start, m.end);
  }
  for (final m in _cardPattern.allMatches(text)) {
    final digits = m.group(0)!.replaceAll(RegExp(r'[ -]'), '');
    if (_looksLikeCard(digits)) add(SignalKind.card, m.start, m.end);
  }
  for (final m in _dateTime.allMatches(text)) {
    add(SignalKind.date, m.start, m.end);
  }
  _detectOtp(text, add);
  for (final m in _phone.allMatches(text)) {
    final digits = m.group(0)!.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 8 && digits.length <= 15) {
      add(SignalKind.phone, m.start, m.end);
    }
  }
  for (final m in _address.allMatches(text)) {
    add(SignalKind.address, m.start, m.end);
  }

  const rank = [
    SignalKind.otp,
    SignalKind.card,
    SignalKind.iban,
    SignalKind.url,
    SignalKind.phone,
    SignalKind.email,
    SignalKind.address,
    SignalKind.date,
  ];
  out.sort((a, b) => rank.indexOf(a.kind).compareTo(rank.indexOf(b.kind)));
  return out;
}

bool hasSensitive(List<ClipSignal> signals) =>
    signals.any((s) => s.isSensitive);

// ------------------------------------------------------------------- patterns

final _url = RegExp(r'''(?:https?://|www\.)[^\s<>"']+''', caseSensitive: false);

final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

/// 13–19 digits, optionally grouped by single spaces or dashes.
final _cardPattern = RegExp(r'(?<![\d-])\d(?:[ -]?\d){12,18}(?![\d-])');

/// Country code, check digits, then 11–30 alphanumerics, optionally in
/// groups of four. Case-insensitive: IBANs are often typed lowercase.
final _ibanPattern = RegExp(
  r'\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b',
  caseSensitive: false,
);

final _phone = RegExp(r'(?<![\w+])(?:\+|00|0)\d[\d ()./-]{6,}\d(?!\w)');

final _dateTime = RegExp(
  r'\b(?:\d{4}-\d{2}-\d{2}(?:[ T]\d{1,2}:\d{2})?'
  r'|\d{1,2}[./]\d{1,2}[./]\d{2,4}'
  r'|\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d{4}'
  r'|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d{1,2}(?:, \d{4})?'
  r'|\d{1,2}:\d{2}(?:\s?[AaPp][Mm])?)\b',
);

/// A house number next to a street word, in English or German, e.g.
/// "221B Baker Street", "Hauptstraße 5", "Unter den Linden 77, 10117 Berlin".
final _address = RegExp(
  r'(?:\b\d{1,5}[A-Za-z]? (?:[A-Z][\wäöüß.-]* ){0,3}'
  r'(?:Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|Lane|Ln\.?|Drive|Dr\.?|Boulevard|Blvd\.?|Way|Court|Ct\.?|Place|Pl\.?)\b'
  r'|\b[A-ZÄÖÜ][\wäöüß-]*(?:straße|strasse|str\.|weg|platz|allee|gasse|ring|damm|ufer)'
  r' \d{1,4}[a-z]?\b)'
  r'(?:,? \d{4,5} [A-ZÄÖÜ][\wäöüß-]+)?',
);

final _otpKeyword = RegExp(
  r'\b(?:code|otp|passcode|pin|verification|verify|one[- ]time|tan|'
  r'bestätigungscode|sicherheitscode|einmalcode|kód|código)\b',
  caseSensitive: false,
);

/// A one-time code: a 4–8 digit run (optionally split "123 456" / "123-456").
/// Either the clip IS the code (6–8 digits, or 4–5 next to a keyword), or the
/// clip is a message that names a code ("Your verification code is 482913").
/// A bare 4-digit clip is more often a year or a PIN-less number than a code.
void _detectOtp(String text, void Function(SignalKind, int, int) add) {
  final t = text.trim();
  final whole = RegExp(r'^(\d{3,4})[ -]?(\d{3,4})$|^(\d{4,8})$').firstMatch(t);
  if (whole != null) {
    final digits = t.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 6 && digits.length <= 8) {
      final s = text.indexOf(t);
      add(SignalKind.otp, s, s + t.length);
    }
    return;
  }
  final kw = _otpKeyword.firstMatch(text);
  if (kw == null) return;
  // The code is the run right AFTER the keyword ("code is 482913", "Code:
  // 4829"), else the nearest one before it ("482913 is your code"). The first
  // number in the message is often a phone number or an amount instead.
  final runs = _otpRun.allMatches(text).toList();
  final after = runs.where((m) => m.start >= kw.end);
  final before = runs.where((m) => m.end <= kw.start);
  final pick = after.isNotEmpty
      ? after.first
      : (before.isNotEmpty ? before.last : null);
  if (pick != null) add(SignalKind.otp, pick.start, pick.end);
}

final _otpRun = RegExp(
  // A separator only rules a run out when a DIGIT is on its other side:
  // "G-582194" and "is 482913." are codes; "2026-10-18" and "1.240,00" are not.
  r'(?<![\d+])(?<!\d[.,:/-])(?:\d{3}[ -]\d{3}|\d{4,8})(?!\d|[.,:/-]\d)',
);

// ------------------------------------------------------------------ checksums

bool _looksLikeCard(String digits) {
  if (digits.length < 13 || digits.length > 19) return false;
  // Major networks start 2–6 (Mastercard 2-series, Amex 3, Visa 4, MC 5,
  // Discover/UnionPay 6). A run of one repeated digit passes Luhn trivially.
  if (!'23456'.contains(digits[0])) return false;
  if (RegExp(r'^(\d)\1+$').hasMatch(digits)) return false;
  return luhnValid(digits);
}

bool luhnValid(String digits) {
  var sum = 0;
  var dbl = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var d = digits.codeUnitAt(i) - 48;
    if (d < 0 || d > 9) return false;
    if (dbl) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    dbl = !dbl;
  }
  return sum % 10 == 0;
}

/// ISO 13616: move the first four characters to the end, map letters to
/// 10..35, and the whole number mod 97 must be 1.
bool isValidIban(String raw) {
  final s = raw.replaceAll(' ', '').toUpperCase();
  if (s.length < 15 || s.length > 34) return false;
  if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(s)) return false;
  final r = s.substring(4) + s.substring(0, 4);
  var rem = 0;
  for (final ch in r.codeUnits) {
    final v = ch >= 65 ? ch - 55 : ch - 48;
    rem = v >= 10 ? (rem * 100 + v) % 97 : (rem * 10 + v) % 97;
  }
  return rem == 1;
}

/// "•••• 4242" for a card, "DE89 •••• 3000" for an IBAN: enough to tell two
/// apart, not enough to use.
String maskSensitive(ClipSignal s) {
  final compact = s.value.replaceAll(RegExp(r'[ -]'), '');
  if (s.kind == SignalKind.card) {
    return '•••• ${compact.substring(compact.length - 4)}';
  }
  if (s.kind == SignalKind.iban) {
    final up = compact.toUpperCase();
    return '${up.substring(0, 4)} •••• ${up.substring(up.length - 4)}';
  }
  return s.value;
}

/// The digits of an OTP, without the space or dash a message split them with.
String otpDigits(ClipSignal s) => s.value.replaceAll(RegExp(r'\D'), '');
