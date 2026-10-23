import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../home/home_screen.dart';
import '../library/library_providers.dart';
import '../library/library_screen.dart';
import '../library/song_select.dart' show selectionActiveProvider;
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
    // tap happened. Feeds Listen Again + taste shelves.
    ref.listen(currentSongProvider, (prev, next) {
      final song = next.value;
      if (song == null || song.id == prev?.value?.id) return;
      ref.read(historyStoreProvider).recordPlay(song.id);
      ref.invalidate(listenAgainProvider);
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
            if (playerOpen) const PlayerScreen(),
            const _GlassWarmer(),
          ],
        ),
      ),
    );
  }
}

/// One-time shader warmup: paints the menu + sheet lens recipes
/// offscreen once at startup so the first real menu/sheet open
/// doesn't stall compiling Impeller programs. Removed right
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
      ],
    );
  }
}
