import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../library/library_providers.dart';
import '../library/library_screen.dart';
import '../needle/needle_search.dart';
import '../search/search_page.dart';
import '../player/player_providers.dart';
import '../player/player_screen.dart';
import '../settings/settings_screen.dart';
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
              Destination.library => const LibraryScreen(
                key: ValueKey('dest-library'),
              ),
              Destination.search => const SearchPage(
                key: ValueKey('dest-search'),
              ),
              Destination.needle => const NeedleSearchPage(
                key: ValueKey('dest-needle'),
              ),
              Destination.settings => const SettingsScreen(
                key: ValueKey('dest-settings'),
              ),
            },
            const NowPlayingDock(),
            if (playerOpen) const PlayerScreen(),
          ],
        ),
      ),
    );
  }
}
