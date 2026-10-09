import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'core/log.dart';
import 'core/theme.dart';
import 'features/player/audio_handler.dart';
import 'features/player/player_providers.dart';
import 'features/setup/setup_gate.dart';
import 'features/shell/shell.dart';

/// Audio init stays first so cold media-resume entries reach a ready
/// handler inside the foreground ANR window; shader warmup never blocks.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ArchLog.init();
  FlutterError.onError = (details) {
    ArchLog.e('flutter', details.exceptionAsString(), details.stack);
    FlutterError.presentError(details);
  };
  runZonedGuarded(
    () async {
      final handler = await AudioService.init(
        builder: () => ArchAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.archstudios.arch_player.channel',
          androidNotificationChannelName: 'Arch Player',
          androidNotificationIcon: 'drawable/ic_stat_music_note',
        ),
      );
      // Glass shaders compile off the critical path: first glass frame may
      // frost for a blink on cold start, then it's glass forever.
      LiquidGlassShaders.ensureLoaded().ignore();
      runApp(
        ProviderScope(
          overrides: [audioHandlerProvider.overrideWithValue(handler)],
          child: const ArchApp(),
        ),
      );
      ArchLog.i('app', 'arch player v2 up');
    },
    (err, stack) => ArchLog.e('zone', err, stack),
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
      home: const SetupGate(child: Shell()),
      builder: (context, child) {
        // Blank is never a symptom: render failures name themselves.
        ErrorWidget.builder = (details) => _CrashCard(details: details);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}

class _CrashCard extends StatelessWidget {
  final FlutterErrorDetails details;
  const _CrashCard({required this.details});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Something broke here',
                  style: TextStyle(color: archPink, fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                details.exceptionAsString().split('\n').first,
                style: const TextStyle(color: inkDim, fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  if (Navigator.of(context).canPop()) Navigator.of(context).pop();
                },
                child: const Text('Go back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
