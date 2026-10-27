import 'dart:async';

import 'package:audio_service/audio_service.dart';import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'core/app_prefs.dart';
import 'core/log.dart';
import 'core/theme.dart';
import 'features/needle/needle_core.dart';
import 'features/metadata/metadata_providers.dart';
import 'features/metadata/metadata_service.dart';
import 'features/player/audio_handler.dart';
import 'features/player/play_guarded.dart';
import 'features/player/player_providers.dart';
import 'features/setup/setup_gate.dart';
import 'features/shell/shell.dart';

/// Audio init stays first so cold media-resume entries reach a ready
/// handler inside the foreground ANR window; shader warmup never blocks.
///
/// No runZonedGuarded: the guarded zone split binding init from runApp
/// (debugCheckZone fired every launch). Modern handling instead -
/// FlutterError for framework errors, platformDispatcher.onError for
/// everything async - with all of it landing in arch.log either way.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ArchLog.init();
  // Needle core (Rust): best-effort at startup, never fatal. A dead
  // bridge disables downloads, never playback - verified by ping.
  await Needle.ensureReady();
  FlutterError.onError = (details) {
    ArchLog.e('flutter', details.exceptionAsString(), details.stack);
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (err, stack) {
    ArchLog.e('zone', err, stack);
    return true;
  };
  // One metadata instance for the whole app: the audio handler needs
  // cached BPM/key for crossfade planning, and the UI providers must
  // read the same cache (no duplicated disk state, no double writes).
  final meta = MetadataService();
  // Warm the musical disk cache before the first cache-only read:
  // cold reads otherwise report unknown until an unrelated
  // full-lane call loads it (an evening of analyses once looked
  // lost to exactly this).
  unawaited(meta.warmMusical());
  final handler = await AudioService.init(
    builder: () => ArchAudioHandler(metadata: meta),
      config: const AudioServiceConfig(
        // Fresh channel id (native side pre-creates it silent HIGH):
        // deleted ids resurrect with prior config, so silence needs
        // an id the system has never seen.
        androidNotificationChannelId: 'com.archstudios.arch_player.media',
        androidNotificationChannelName: 'Arch Player',
        androidNotificationIcon: 'drawable/ic_stat_music_note',
        // Pinned while playing: swiping the notification must never
        // orphan background audio into a silent death.
        androidNotificationOngoing: true,
      ),
  );
  // Glass shaders compile off the critical path: first glass frame may
  // frost for a blink on cold start, then it's glass forever.
  LiquidGlassShaders.ensureLoaded().ignore();
  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(handler),
        metadataServiceProvider.overrideWithValue(meta),
      ],
      child: const ArchApp(),
    ),
  );
  ArchLog.i('app', 'arch player v2 up');
}

class ArchApp extends ConsumerWidget {
  const ArchApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appThemeModeProvider);
    return MaterialApp(
      title: 'Arch Player',
      debugShowCheckedModeBanner: false,
      theme: archTheme(),
      darkTheme: archDarkTheme(amoled: mode == AppThemeMode.amoled),
      themeMode: switch (mode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark || AppThemeMode.amoled => ThemeMode.dark,
      },
      // Neutral overscroll app-wide: the default glow paints in
      // colorScheme.primary (our pink-red) and reads as an error
      // flash at every list edge.
      scrollBehavior: const _NoGlowBehavior(),
      home: const SetupGate(child: Shell()),
      builder: (context, child) {
        // Blank is never a symptom: render failures name themselves.
        ErrorWidget.builder = (details) => _CrashCard(details: details);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}

class _NoGlowBehavior extends ScrollBehavior {
  const _NoGlowBehavior();

  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return StretchingOverscrollIndicator(
      axisDirection: details.direction,
      child: child,
    );
  }
}

class _CrashCard extends ConsumerWidget {
  final FlutterErrorDetails details;
  const _CrashCard({required this.details});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // File first: Honor eats logcat, arch.log doesn't. Full exception
    // + stack so the next one names itself without a device round-trip.
    ArchLog.e('crash', details.exceptionAsString(), details.stack);
    final lines = details.exceptionAsString().split('\n').take(5).join('\n');
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
                lines,
                style: const TextStyle(color: inkDim, fontSize: 13),
              ),
              const SizedBox(height: 4),
              const Text(
                'Details saved to arch.log',
                style: TextStyle(color: inkDim, fontSize: 11),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton(
                    onPressed: () {
                      resetPlayerFlags(ref);
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





