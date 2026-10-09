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
  // Audio first: a cold media-resume entry must reach a ready handler in
  // well under the 10s foreground ANR window. Shader warmup must never
  // block the entrypoint, so it runs unawaited after init.
  final handler = await AudioService.init(
    builder: () => ArchAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.archstudios.arch_player.channel',
      androidNotificationChannelName: 'Arch Player',
      androidNotificationIcon: 'drawable/ic_stat_music_note',
    ),
  );
  // Compile glass shaders for first-frame glass instead of first-frame
  // frost. Fire-and-forget: ghost starts have no UI to warm for.
  LiquidGlassShaders.ensureLoaded().ignore();
  // Bounded image caches: unbounded decoded images starved Impeller
  // textures until content painted black and self-healed. Never again.
  PaintingBinding.instance.imageCache.maximumSize = 100;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 << 20;
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
      builder: (context, child) {
        ErrorWidget.builder = (details) => _CrashCard(details: details);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}

/// Blank is never a symptom: any render failure names itself with a way back.
class _CrashCard extends StatelessWidget {
  final FlutterErrorDetails details;
  const _CrashCard({required this.details});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ink,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Something broke here', style: TextStyle(color: archRed, fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                details.exceptionAsString().split('\n').first,
                style: const TextStyle(color: inkTextDim, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton(
                    onPressed: () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: const Text('Go back'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
