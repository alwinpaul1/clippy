import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/signals/clip_signals.dart';

/// Opens a clip's link, number, email or address in the system app. No
/// plugin: macOS (not sandboxed) and Windows hand the URI to the OS; Android
/// fires an ACTION_VIEW intent through the app's own channel.
///
/// Only http(s), tel and mailto ever leave here. A clip's text is untrusted
/// (anyone in the room could have copied it), so a `file:` or custom-scheme
/// URI is refused rather than opened.
abstract class LinkOpener {
  static const _channel = MethodChannel('clippy/share');

  /// The URI an action opens for [s], or null if the signal has no action.
  static Uri? uriFor(ClipSignal s) {
    switch (s.kind) {
      case SignalKind.url:
        final v = s.value.toLowerCase().startsWith('www.')
            ? 'https://${s.value}'
            : s.value;
        final u = Uri.tryParse(v);
        return (u != null && (u.scheme == 'https' || u.scheme == 'http'))
            ? u
            : null;
      case SignalKind.phone:
        return Uri(
          scheme: 'tel',
          path: s.value.replaceAll(RegExp(r'[^\d+]'), ''),
        );
      case SignalKind.email:
        return Uri(scheme: 'mailto', path: s.value);
      case SignalKind.address:
        return Uri.https('www.google.com', '/maps/search/', {
          'api': '1',
          'query': s.value,
        });
      default:
        return null;
    }
  }

  static Future<bool> open(Uri uri) async {
    if (kIsWeb ||
        !const {'https', 'http', 'tel', 'mailto'}.contains(uri.scheme)) {
      return false;
    }
    final url = uri.toString();
    try {
      if (Platform.isAndroid) {
        return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ??
            false;
      }
      if (Platform.isMacOS) {
        await Process.start('open', [url]);
        return true;
      }
      if (Platform.isWindows) {
        // The shell's URL handler; `start` would need cmd.exe and quoting.
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
        return true;
      }
    } catch (_) {}
    return false;
  }
}
