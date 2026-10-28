import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction;
import '../shell/morph_menu.dart' show showMorphMenu;
import '../shell/dock.dart';
import 'artist_hub_page.dart';
import 'data/history_store.dart';
import 'library_chrome.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Artists: circular portraits, searchable A–Z, grid or list. Tapping
/// an artist opens the shallow hub (WA0010 grammar): portrait, name,
/// Play / Shuffle, top songs and albums. Long-press still opens the
/// fan sheet. The header `...` owns the view switch.
class ArtistsPage extends ConsumerStatefulWidget {
  const ArtistsPage({super.key});

  @override
  ConsumerState<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends ConsumerState<ArtistsPage> {
  bool _grid = true;

  Future<void> _openViewMenu(BuildContext buttonContext) async {
    final value = await showMorphMenu(
      context: buttonContext,
      items: [
        MenuAction(
          icon: CupertinoIcons.square_grid_2x2,
          label: 'Grid',
          value: 'grid',
          selected: _grid,
        ),
        MenuAction(
          icon: CupertinoIcons.list_bullet,
          label: 'List',
          value: 'list',
          selected: !_grid,
        ),
      ],
    );
    if (!mounted) return;
    final bool? wantsGrid = switch (value) {
      'grid' => true,
      'list' => false,
      _ => null,
    };
    if (wantsGrid == null || wantsGrid == _grid) return;
    HapticFeedback.selectionClick();
    setState(() {
      _grid = wantsGrid;
    });
  }

  @override
  Widget build(BuildContext context) {
    final artists = ref.watch(artistsProvider);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          DockScrollReporter(
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 64)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Icon(
                              CupertinoIcons.chevron_left,
                              color:
                                  Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Artists',
                            style: TextStyle(
                              fontFamily: 'ArchSerif',
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        Builder(
                          builder: (buttonContext) => GestureDetector(
                            onTap: () => _openViewMenu(buttonContext),
                            // Rigid lens: no flex touch here. Flex listens
                            // on a raw Listener outside the gesture arena,
                            // so it deforms through scroll drags and fights
                            // the CustomScrollView this header rides in.
                            child: LiquidGlassLens(
                              style: ArchGlass.trigger(
                                  amoled: isAmoledScheme(buttonContext)),
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                  child: Icon(
                                    CupertinoIcons.ellipsis,
                                    color: Theme.of(buttonContext)
                                        .colorScheme
                                        .onSurface,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverToBoxAdapter(
                  child: LibraryCollapsingSearch(
                    hint: 'Search artists',
                    onChanged: (q) =>
                        ref.read(libraryQueryProvider.notifier).state = q,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                Builder(
                  builder: (context) {
                    final ordered = List<ArtistEntry>.of(artists)
                      ..sort(
                        (a, b) => a.name.toLowerCase().compareTo(
                          b.name.toLowerCase(),
                        ),
                      );
                    if (ordered.isEmpty) {
                      return SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 32),
                            child: Text(
                              'No artists match.',
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ),
                          ),
                        ),
                      );
                    }
                    final perRow = _grid ? 2 : 1;
                    final rows = <List<ArtistEntry>>[];
                    for (var r = 0; r < ordered.length; r += perRow) {
                      rows.add(
                        ordered.sublist(
                          r,
                          r + perRow > ordered.length
                              ? ordered.length
                              : r + perRow,
                        ),
                      );
                    }
                    return SliverList.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, r) {
                        final row = rows[r];
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var c = 0; c < row.length; c++) ...[
                                if (c > 0) const SizedBox(width: 12),
                                Expanded(
                                  child: _grid
                                      ? _gridCard(context, row[c])
                                      : _listTile(context, row[c]),
                                ),
                              ],
                              if (_grid && row.length == 1)
                                const Expanded(child: SizedBox.shrink()),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 140)),
              ],
            ),
          ),
          const NowPlayingDock(),
        ],
      ),
    );
  }

  // ---- Rows -------------------------------------------------------

  Widget _gridCard(BuildContext context, ArtistEntry entry) {
    final rep = entry.songs.firstWhere(
      (s) => s.path.isNotEmpty,
      orElse: () => entry.songs.first,
    );
    final isFollowed = ref.watch(followedProvider).contains(entry.name);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        ArtistHubPage.openIfAbsent(context, entry.name);
      },
      onLongPress: () => showArtistFanSheet(context, ref, entry.name),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: rep.path.isNotEmpty
                        ? FileArtImage(
                            path: rep.path,
                            albumId: rep.albumId,
                            size: 360,
                            radius: 20,
                          )
                        : Container(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: Icon(
                              CupertinoIcons.person_fill,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              size: 42,
                            ),
                          ),
                  ),
                ),
                if (isFollowed)
                  const Positioned(
                    top: 8,
                    left: 8,
                    child: Icon(Icons.check_circle, color: archPink, size: 18),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          Text(
            '${entry.songs.length} songs',
            maxLines: 1,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _listTile(BuildContext context, ArtistEntry entry) {
    final rep = entry.songs.firstWhere(
      (s) => s.path.isNotEmpty,
      orElse: () => entry.songs.first,
    );
    final isFollowed = ref.watch(followedProvider).contains(entry.name);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        ArtistHubPage.openIfAbsent(context, entry.name);
      },
      onLongPress: () => showArtistFanSheet(context, ref, entry.name),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 44,
                height: 44,
                child: rep.path.isNotEmpty
                    ? FileArtImage(
                        path: rep.path,
                        albumId: rep.albumId,
                        size: 120,
                        radius: 0,
                      )
                    : Container(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: Icon(
                          CupertinoIcons.person_fill,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isFollowed)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.check_circle,
                            color: archPink,
                            size: 15,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    '${entry.songs.length} songs',
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                        fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(CupertinoIcons.chevron_right,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 16),
          ],
        ),
      ),
    );
  }
}

/// Fan sheet: long-press any artist anywhere for their five most
/// recent songs plus play and view actions. Sheet resolves its own
/// songs by name, so collages, lists and rails all share one call.
Future<void> showArtistFanSheet(
  BuildContext context,
  WidgetRef ref,
  String artist,
) async {
  HapticFeedback.mediumImpact();
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.7,
    ),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: _ArtistFanSheet(artist: artist),
    ),
  );
}

class _ArtistFanSheet extends ConsumerWidget {
  final String artist;
  const _ArtistFanSheet({required this.artist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.08)),
      ),
      child: FutureBuilder<List<Song>>(
        future: _recentSongs(ref, artist),
        builder: (context, snap) {
          final songs = snap.data ?? const [];
          final rep = songs.isNotEmpty
              ? songs.firstWhere(
                  (s) => s.path.isNotEmpty,
                  orElse: () => songs.first,
                )
              : null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: (rep != null && rep.path.isNotEmpty)
                          ? FileArtImage(
                              path: rep.path,
                              albumId: rep.albumId,
                              size: 112,
                              radius: 0,
                            )
                          : Container(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              child: Icon(
                                CupertinoIcons.person_fill,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'ArchSerif',
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Fan deck',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'View artist',
                    icon: const Icon(
                      CupertinoIcons.arrow_up_right_circle,
                      color: archPink,
                      size: 30,
                    ),
                    onPressed: () {
                      Navigator.of(context).maybePop();
                      ArtistHubPage.openIfAbsent(context, artist);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (snap.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(
                    color: archPink,
                    strokeWidth: 2,
                  ),
                )
              else if (songs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No recent songs found.',
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant),
                  ),
                )
              else
                for (var i = 0; i < songs.length; i++)
                  SongRow(
                    song: songs[i],
                    isCurrent: false,
                    onTap: () => _playFromFan(context, ref, songs, i),
                  ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: songs.isEmpty
                      ? null
                      : () => _playFromFan(context, ref, songs, 0),
                  icon: const Icon(CupertinoIcons.play_fill, size: 16),
                  label: const Text('Play'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _playFromFan(
    BuildContext context,
    WidgetRef ref,
    List<Song> songs,
    int i,
  ) async {
    HapticFeedback.mediumImpact();
    Navigator.of(context).maybePop();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(songs[i], songs));
  }
}

/// Five most recent plays for one artist name. Shared by the fan
/// sheet everywhere it opens.
Future<List<Song>> recentSongsFor(
  List<Song> songs,
  Map<int, PlayRecord> history,
  String artist,
) async {
  final key = artist.trim().toLowerCase();
  final entries = [
    for (final e in history.entries)
      if (e.value.lastMs > 0) e,
  ]..sort((a, b) => b.value.lastMs.compareTo(a.value.lastMs));
  final byId = {for (final s in songs) s.id: s};
  final out = <Song>[];
  for (final e in entries) {
    final s = byId[e.key];
    if (s == null || out.length >= 5) break;
    if (!artistsOverlap(s.artist, key)) continue;
    if (out.any((o) => o.id == s.id)) continue;
    out.add(s);
  }
  return out;
}

Future<List<Song>> _recentSongs(WidgetRef ref, String artist) async {
  final songs = ref.read(songsProvider).value ?? [];
  final history = await ref.read(historyStoreProvider).read();
  return recentSongsFor(songs, history, artist);
}
