import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps Clippy alive and syncing on desktop after its window is closed.
///
/// Closing the window (red button / taskbar close) hides it instead of
/// quitting, and a menu-bar (macOS) / system-tray (Windows) icon stays put so
/// you can reopen it or quit for real. The clipboard sync lives in the main
/// isolate, which stays running as long as the process does. No-op off desktop.
///
/// The tray icon bounces and winks like the download-page mascot:
/// - bob: 5.5s ease-in-out, peak at 45% (translate + slight rotate)
/// - blink: 4.2s linear, closed eyes around 95% of the cycle
class DesktopTray with TrayListener, WindowListener {
  DesktopTray._();
  static final DesktopTray instance = DesktopTray._();

  static bool get isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  // Pre-rendered bounce samples (amount 0..1) × open/blink — see
  // assets/icon/tray_anim/. Matches website keyframes in server/web/index.html.
  static const _bobFrames = 9;
  static const _bobMs = 5500;
  static const _blinkMs = 4200;
  static const _tickMs = 90; // ~11 fps; enough for a soft bob without thrashing

  Timer? _anim;
  String? _lastIcon;
  bool _setting = false;

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
    await _setIcon(_framePath(0, closed: false));
    await trayManager.setToolTip('Clippy — clipboard sync');
    await trayManager.setContextMenu(
      Menu(items: [
        MenuItem(key: 'show', label: 'Open Clippy'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit Clippy'),
      ]),
    );

    _startAnim();
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Bounce amount 0..1 for bob-cycle progress t∈[0,1], peak at 45% (CSS).
  static double _bobAmount(double t) {
    double ease(double u) => 0.5 - 0.5 * math.cos(math.pi * u.clamp(0.0, 1.0));
    if (t <= 0.45) return ease(t / 0.45);
    return 1.0 - ease((t - 0.45) / 0.55);
  }

  static String _framePath(int bobIndex, {required bool closed}) {
    final i = bobIndex.clamp(0, _bobFrames - 1);
    final tag = closed ? 'blink' : 'open';
    if (Platform.isWindows) {
      return 'assets/icon/tray_anim/win_${i.toString().padLeft(2, '0')}_$tag.ico';
    }
    return 'assets/icon/tray_anim/mac_${i.toString().padLeft(2, '0')}_$tag.png';
  }

  Future<void> _setIcon(String path) async {
    if (path == _lastIcon) return;
    _lastIcon = path;
    await trayManager.setIcon(path, isTemplate: Platform.isMacOS);
  }

  void _startAnim() {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    if (_anim != null) return;
    final started = DateTime.now().millisecondsSinceEpoch;
    _anim = Timer.periodic(const Duration(milliseconds: _tickMs), (_) async {
      if (_setting) return;
      _setting = true;
      try {
        final now = DateTime.now().millisecondsSinceEpoch - started;
        final bobT = (now % _bobMs) / _bobMs;
        final blinkT = (now % _blinkMs) / _blinkMs;
        final amount = _bobAmount(bobT);
        final frame = (amount * (_bobFrames - 1)).round();
        // Website: scaleY(.1) at 95% of the 4.2s blink cycle (~92–98% closed).
        final closed = blinkT >= 0.92 && blinkT <= 0.98;
        await _setIcon(_framePath(frame, closed: closed));
      } catch (_) {
        // Icon swap can fail mid-quit; ignore.
      } finally {
        _setting = false;
      }
    });
  }

  void _stopAnim() {
    _anim?.cancel();
    _anim = null;
  }

  // --- window close -> hide, don't quit ---
  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
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
        _stopAnim();
        await trayManager.destroy();
        exit(0);
    }
  }
}
