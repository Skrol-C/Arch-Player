import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../home/home_screen.dart';
import '../library/library_providers.dart';
import '../library/library_screen.dart';
import '../library/song_select.dart' show selectionActiveProvider;
import '../metadata/metadata_providers.dart';
import '../needle/needle_hub.dart';
import '../search/search_page.dart';
import '../player/player_providers.dart';
import '../player/player_screen.dart';
import 'dock.dart';

/// App shell: destination content + the shared dock. Scroll intent is
/// reported up for the pill collapse driver.
class Shell extends ConsumerWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dest = ref.watch(destinationProvider);
    final playerOpen = ref.watch(playerOpenProvider);
    ArchLog.i('nav', 'shell build dest=$dest playerOpen=$playerOpen');
    // One hook: every newly current song counts as listened, wherever the
    // tap happened. Feeds Listen Again + taste shelves. Musical info
    // (BPM/key) resolves alongside for the automix lane — log only,
    // the ordering engine consumes it later.
    ref.listen(currentSongProvider, (prev, next) {
      final song = next.value;
      if (song == null || song.id == prev?.value?.id) return;
      ref.read(historyStoreProvider).recordPlay(song.id);
      ref.invalidate(listenAgainProvider);
      _logMusical(ref, song);
    });
    // Screen stays awake while the player is open, sleeps with it.
    ref.listen(playerOpenProvider, (_, open) {
      setKeepAwake(open);
    });
    return Scaffold(
      body: DockScrollReporter(
        child: Stack(
          fit: StackFit.expand,
          children: [
            switch (dest) {
              Destination.home => const HomeScreen(
                key: ValueKey('dest-home'),
              ),
              Destination.library => const LibraryScreen(
                key: ValueKey('dest-library'),
              ),
              Destination.search => const SearchPage(
                key: ValueKey('dest-search'),
              ),
              Destination.needle => const NeedleHubPage(
                key: ValueKey('dest-needle'),
              ),
            },
            // Select mode owns the bottom edge: the docked sheet
            // replaces the pill, the mini player sits behind it.
            if (!ref.watch(selectionActiveProvider))
              const NowPlayingDock(),
            // Overlay only when no pushed player route exists: both
            // mounting PlayerScreen doubles live controllers and trips
            // element asserts on push/pop.
            if (playerOpen && !ref.watch(playerRouteOpenProvider))
              const PlayerScreen(),
            const _GlassWarmer(),
          ],
        ),
      ),
    );
  }
}

/// Automix lane probe: resolve BPM/key for the new current song and
/// log the verdict (embedded vs network vs unknown). Fire-and-forget;
/// failures stay off the playback path by construction (provider).
Future<void> _logMusical(WidgetRef ref, Song song) async {
  try {
    final info = await ref.read(
      musicalInfoProvider('${song.artist}\x00${song.title}\x00${song.path}').future,
    );
    if (info == null || info.isEmpty) {
      ArchLog.i('musical', 'unknown ${song.artist} - ${song.title}');
    } else {
      ArchLog.i(
        'musical',
        '${info.source} ${song.artist} - ${song.title} '
        'bpm=${info.bpm?.toStringAsFixed(1)} key=${info.keyOf} open=${info.openKey}',
      );
    }
  } catch (_) {}
}

/// One-time shader warmup: paints the menu + sheet + dock lens recipes
/// offscreen once at startup so the first real menu/sheet open or pill
/// split doesn't stall compiling Impeller programs. Removed right
/// after; reduced-motion still cuts all travel.
class _GlassWarmer extends StatefulWidget {
  const _GlassWarmer();

  @override
  State<_GlassWarmer> createState() => _GlassWarmerState();
}

class _GlassWarmerState extends State<_GlassWarmer> {
  bool _warm = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _warm = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_warm) return const SizedBox.shrink();
    // On-screen (2px, near-invisible) so Impeller actually
    // compiles the programs; offscreen layers get culled and
    // would warm nothing. Under everything, gone in <1s.
    return const Positioned(
      left: 0,
      top: 0,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.01,
          child: _WarmLenses(),
        ),
      ),
    );
  }
}

class _WarmLenses extends StatelessWidget {
  const _WarmLenses();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LiquidGlassLens(
          style: ArchGlass.menuMorphed(1),
          child: const SizedBox(width: 2, height: 2),
        ),
        LiquidGlassLens(
          style: ArchGlass.sheet(),
          child: const SizedBox(width: 2, height: 2),
        ),
        // Dock recipes (full pill + minis are capsule, lobes circle):
        // without these the first split shows plain lenses for ~200ms
        // while Impeller compiles the programs.
        LiquidGlassLens(
          style: ArchGlass.capsule(),
          child: const SizedBox(width: 2, height: 2),
        ),
        LiquidGlassLens(
          style: ArchGlass.circle(),
          child: const SizedBox(width: 2, height: 2),
        ),
      ],
    );
  }
}
