import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/clip_controller.dart';
import 'app/home_page.dart';
import 'app/pairing_page.dart';
import 'core/pairing/pairing_key.dart';
import 'platform/foreground_service.dart';
import 'platform/secure_key_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ForegroundServiceManager.init();
  runApp(const ClippyApp());
}

class ClippyApp extends StatelessWidget {
  const ClippyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clippy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF6C4DF6),
      ),
      home: const ClippyRoot(),
    );
  }
}

class ClippyRoot extends StatefulWidget {
  const ClippyRoot({super.key});

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
      id = 'dev-${List.generate(6, (_) => rnd.nextInt(36).toRadixString(36)).join()}';
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return PairingPage(onPaired: _onPaired);
    }
    return HomePage(
      controller: controller,
      pairing: _pairing!,
      onUnpair: _onUnpair,
    );
  }
}
