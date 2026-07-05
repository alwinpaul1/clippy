import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps Clippy alive and syncing on desktop after its window is closed.
///
/// Closing the window (red button / taskbar close) hides it instead of
/// quitting, and a menu-bar (macOS) / system-tray (Windows) icon stays put so
/// you can reopen it or quit for real. The clipboard sync lives in the main
/// isolate, which stays running as long as the process does. No-op off desktop.
class DesktopTray with TrayListener, WindowListener {
  DesktopTray._();
  static final DesktopTray instance = DesktopTray._();

  static bool get isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  // Animated menu-bar icon: while Clippy runs hidden in the background, it winks
  // every few seconds (like the in-app mascot) so you can see it's alive.
  // macOS only — Windows tray icons don't take a template PNG the same way.
  static String get _openIcon =>
      Platform.isWindows ? 'assets/icon/tray_icon.ico' : 'assets/icon/tray_template.png';
  static const _blinkIcon = 'assets/icon/tray_template_blink.png';
  Timer? _wink;

  Future<void> init() async {
    if (!isDesktop) return;

    await windowManager.ensureInitialized();
    // The window starts hidden (hiddenWindowAtLaunch in MainFlutterWindow);
    // reveal it once window_manager is ready.
    windowManager.waitUntilReadyToShow(
      const WindowOptions(title: 'Clippy', titleBarStyle: TitleBarStyle.hidden),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    // Intercept the window close so it hides (keeps syncing) instead of exiting.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    trayManager.addListener(this);
    await trayManager.setIcon(
      _openIcon,
      isTemplate: Platform.isMacOS, // adapt to light/dark menu bar
    );
    await trayManager.setToolTip('Clippy — clipboard sync');
    await trayManager.setContextMenu(
      Menu(items: [
        MenuItem(key: 'show', label: 'Open Clippy'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit Clippy'),
      ]),
    );
  }

  Future<void> _show() async {
    _stopWink();
    await windowManager.show();
    await windowManager.focus();
  }

  // Periodic wink while backgrounded: swap to the closed-eyes frame briefly,
  // then back. macOS menu bar only.
  void _startWink() {
    if (!Platform.isMacOS || _wink != null) return;
    _wink = Timer.periodic(const Duration(milliseconds: 4200), (_) async {
      await trayManager.setIcon(_blinkIcon, isTemplate: true);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      await trayManager.setIcon(_openIcon, isTemplate: true);
    });
  }

  void _stopWink() {
    _wink?.cancel();
    _wink = null;
    if (Platform.isMacOS) {
      trayManager.setIcon(_openIcon, isTemplate: true);
    }
  }

  // --- window close -> hide, don't quit ---
  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
      _startWink(); // now running in the background — show it's alive
    }
  }

  // --- tray interactions ---
  @override
  void onTrayIconMouseDown() => _show(); // left click reopens

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _show();
      case 'quit':
        // The one real quit. Hard-exit so it bypasses macOS
        // applicationShouldTerminate (which now cancels Cmd+Q / Dock-Quit to
        // keep syncing in the menu bar). Nothing to flush — sync state is
        // server-authoritative and prefs are written on change.
        await trayManager.destroy();
        exit(0);
    }
  }
}
