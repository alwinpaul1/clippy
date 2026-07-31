import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'share_channel.dart';

/// Last Build.MODEL resolved natively, so the background-sync isolate can reuse
/// it. That isolate runs its own engine with no MainActivity method channel, so
/// without this it falls back to device_info_plus — and that reads the serial.
const _modelCacheKey = 'clippy.deviceModel.v1';

/// A short, human-friendly name for THIS device, shown on synced clips
/// (e.g. "Alwin's MacBook Pro", "SM-S918B"). Best-effort; falls back to the
/// hostname. Travels as cleartext metadata alongside each clip.
Future<String> resolveDeviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      // Native Build.MODEL rather than device_info_plus: the plugin builds its
      // whole AndroidDeviceInfo eagerly, which calls Build.getSerial() — denied
      // on Android 10+ and logged as a permission violation. An app whose pitch
      // is that it never sees an identity should not reach for the device
      // serial, even accidentally through a plugin.
      final prefs = await SharedPreferences.getInstance();

      // 1) Main isolate: MainActivity's channel is live, so ask it directly and
      //    cache the answer for the background isolate.
      final model = await ShareChannel.deviceModel();
      if (model != null) {
        if (prefs.getString(_modelCacheKey) != model) {
          await prefs.setString(_modelCacheKey, model);
        }
        return model;
      }

      // 2) Background-sync isolate: no Activity, so no channel. Reuse whatever
      //    the main isolate cached rather than waking the plugin.
      final cached = prefs.getString(_modelCacheKey)?.trim();
      if (cached != null && cached.isNotEmpty) return cached;

      // 3) Genuinely first run in the background before the UI ever opened.
      //    Costs one getSerial denial, once, and populates the cache.
      final a = await info.androidInfo;
      final m = a.model.trim();
      if (m.isNotEmpty) await prefs.setString(_modelCacheKey, m);
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
