import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/theme.dart';
import 'features/player/audio_handler.dart';
import 'features/player/player_providers.dart';
import 'features/shell/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Compile glass shaders before the first frame: first glass is glass,
  // never first-frame frost.
  await LiquidGlassShaders.ensureLoaded();
  final handler = await AudioService.init(
    builder: () => ArchAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.archstudios.arch_player.channel',
      androidNotificationChannelName: 'Arch Player',
      androidNotificationIcon: 'drawable/ic_stat_music_note',
    ),
  );
  runApp(
    ProviderScope(
      overrides: [audioHandlerProvider.overrideWithValue(handler)],
      child: const ArchApp(),
    ),
  );
}

class ArchApp extends StatelessWidget {
  const ArchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arch Player',
      debugShowCheckedModeBanner: false,
      theme: archTheme(),
      home: const _PermissionGate(),
    );
  }
}

class _PermissionGate extends StatefulWidget {
  const _PermissionGate();

  @override
  State<_PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<_PermissionGate> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final status = await Permission.audio.status;
    if (status.isGranted || status.isLimited) {
      await _enter();
      return;
    }
    // Pre-33 fallback.
    final storage = await Permission.storage.status;
    if (storage.isGranted || storage.isLimited) {
      await _enter();
      return;
    }
    if (!mounted) return;
    setState(() => _granted = false);
  }

  /// Music allowed: ask for notifications (best-effort), then enter.
  Future<void> _enter() async {
    await Permission.notification.request();
    if (!mounted) return;
    setState(() => _granted = true);
  }

  Future<void> _request() async {
    var status = await Permission.audio.request();
    status = status.isDenied ? await Permission.storage.request() : status;
    // Notifications for media controls (33+). Best-effort, never blocking.
    await Permission.notification.request();
    if (!mounted) return;
    setState(() => _granted = status.isGranted || status.isLimited);
  }

  @override
  Widget build(BuildContext context) {
    if (_granted == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: archRed)));
    }
    if (!_granted!) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Arch needs your music to play anything.'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _request, child: const Text('Allow music access')),
            ],
          ),
        ),
      );
    }
    return const Shell();
  }
}
