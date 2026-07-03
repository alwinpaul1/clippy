import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

/// A short, human-friendly name for THIS device, shown on synced clips
/// (e.g. "Alwin's MacBook Pro", "SM-S918B"). Best-effort; falls back to the
/// hostname. Travels as cleartext metadata alongside each clip.
Future<String> resolveDeviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      final model = a.model.trim();
      return model.isNotEmpty ? model : 'Android';
    }
    if (Platform.isIOS) {
      final i = await info.iosInfo;
      return i.name.isNotEmpty ? i.name : 'iPhone';
    }
    if (Platform.isMacOS) {
      final m = await info.macOsInfo;
      return m.computerName.isNotEmpty ? m.computerName : 'Mac';
    }
    if (Platform.isWindows) {
      return (await info.windowsInfo).computerName;
    }
    if (Platform.isLinux) {
      return (await info.linuxInfo).prettyName;
    }
  } catch (_) {
    // Fall through to hostname.
  }
  return Platform.localHostname;
}
