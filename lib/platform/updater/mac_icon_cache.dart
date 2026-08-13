import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Makes macOS redraw the app icon after a self-update.
///
/// The updater replaces `/Applications/Clippy.app` in place with `ditto`, which
/// copies the timestamps out of the zip. The swapped bundle can therefore carry
/// an mtime OLDER than the icon macOS already cached for that path, and nothing
/// tells LaunchServices the bundle changed. The Dock, Finder, Spotlight and
/// Launchpad keep drawing the previous release's icon — permanently, and across
/// every later update, because each swap repeats the mistake.
///
/// [DesktopUpdater] now refreshes the icon itself after the swap. That is not
/// enough on its own: the updater that performs a swap lives in the OLD build,
/// so that fix only reaches users one release later. This runs in the NEW build
/// on its first launch, which repairs installs that arrived through an older
/// updater. Keep both — they cover different releases.
class MacIconCache {
  MacIconCache._();

  static const _prefsKey = 'mac_icon_refresh_build';

  static const _lsregister =
      '/System/Library/Frameworks/CoreServices.framework/Frameworks'
      '/LaunchServices.framework/Support/lsregister';

  /// Re-registers the bundle once per build number. Safe to call on every
  /// platform and every launch; it does nothing after the first run of a build.
  static Future<void> refreshForNewBuild() async {
    if (!Platform.isMacOS) return;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber;
      if (build.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_prefsKey) == build) return;

      // resolvedExecutable is <app>/Contents/MacOS/clippy.
      final app = File(Platform.resolvedExecutable).parent.parent.parent.path;
      if (!app.endsWith('.app')) return;

      // `touch` moves the bundle mtime forward, so the cached icon is stale by
      // date as well as by registration. Only the mtime changes, so the code
      // signature stays valid.
      await Process.run('touch', [app]);
      await Process.run(_lsregister, ['-f', app]);

      // Recorded last, so a failed refresh runs again on the next launch.
      await prefs.setString(_prefsKey, build);
    } catch (_) {
      // A stale icon is cosmetic. Never let this break startup.
    }
  }
}
