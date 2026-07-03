import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/clip_controller.dart';
import 'app/home_page.dart';
import 'app/pairing_page.dart';
import 'app/theme.dart';
import 'app/theme_controller.dart';
import 'core/pairing/pairing_key.dart';
import 'platform/desktop_tray.dart';
import 'platform/foreground_service.dart';
import 'platform/secure_key_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ForegroundServiceManager.init();
  // Desktop: menu-bar / tray icon + hide-on-close so Clippy keeps syncing in
  // the background after its window is closed (no-op on mobile).
  await DesktopTray.instance.init();
  final theme = ThemeController();
  await theme.load();
  runApp(ClippyApp(theme: theme));
}

class ClippyApp extends StatelessWidget {
  final ThemeController theme;
  const ClippyApp({super.key, required this.theme});

  ThemeData _themeData(ClippyColors c) {
    final brightness = c.isDark ? Brightness.dark : Brightness.light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: c.bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: c.green,
        brightness: brightness,
        surface: c.bg,
      ),
      extensions: [c],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: theme,
      builder: (context, mode, _) => MaterialApp(
        title: 'Clippy',
        debugShowCheckedModeBanner: false,
        theme: _themeData(ClippyColors.light),
        darkTheme: _themeData(ClippyColors.dark),
        themeMode: mode,
        home: ClippyRoot(theme: theme),
      ),
    );
  }
}

class ClippyRoot extends StatefulWidget {
  final ThemeController theme;
  const ClippyRoot({super.key, required this.theme});

  @override
  State<ClippyRoot> createState() => _ClippyRootState();
}

class _ClippyRootState extends State<ClippyRoot> {
  final _keyStore = const SecureKeyStore();
  ClipController? _controller;
  PairingKey? _pairing;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('clippy.deviceId');
    if (id == null) {
      final rnd = Random.secure();
      id =
          'dev-${List.generate(6, (_) => rnd.nextInt(36).toRadixString(36)).join()}';
      await prefs.setString('clippy.deviceId', id);
    }
    return id;
  }

  Future<void> _bootstrap() async {
    PairingKey? key;
    // Dev/test hook: pass --dart-define=CLIPPY_DEV_KEY=<base64> to auto-pair
    // without touching the keychain (works on unsigned local builds).
    const devKey = String.fromEnvironment('CLIPPY_DEV_KEY');
    if (devKey.isNotEmpty) {
      key = PairingKey.fromQrPayload(devKey);
    } else {
      key = await _keyStore.load();
    }
    if (key != null) {
      await _startWith(key);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _startWith(PairingKey key) async {
    final controller = ClipController(deviceId: await _deviceId());
    await controller.start(key);
    _controller = controller;
    _pairing = key;
  }

  Future<void> _onPaired(PairingKey key) async {
    await _keyStore.save(key);
    await _startWith(key);
    if (mounted) setState(() {});
  }

  Future<void> _onUnpair() async {
    await ForegroundServiceManager.stop();
    await _keyStore.clear();
    _controller?.dispose();
    setState(() {
      _controller = null;
      _pairing = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: context.ck.bg,
        body: Center(child: CircularProgressIndicator(color: context.ck.green)),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return PairingPage(onPaired: _onPaired);
    }
    return HomePage(
      controller: controller,
      pairing: _pairing!,
      theme: widget.theme,
      onUnpair: _onUnpair,
    );
  }
}
