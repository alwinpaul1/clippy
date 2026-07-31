import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

import 'share_channel.dart';

/// A short, human-friendly name for THIS device, shown on synced clips
/// (e.g. "Alwin's MacBook Pro", "SM-S918B"). Best-effort; falls back to the
/// hostname. Travels as cleartext metadata alongside each clip.
Future<String> resolveDeviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      // Native Build.MODEL rather than device_info_plus: the plugin builds its
      // whole AndroidDeviceInfo eagerly, which calls Build.getSerial() and gets
      // denied on Android 10+ ("reportAccessDeniedToReadIdentifiers"). Same
      // value, without an app that promises it never sees an identity reaching
      // for the device serial. Falls back to the plugin if the channel is gone.
      final model = await ShareChannel.deviceModel();
      if (model != null) return model;
      final a = await info.androidInfo;
      final m = a.model.trim();
      return m.isNotEmpty ? m : 'Android';
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
