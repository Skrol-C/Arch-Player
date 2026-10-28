import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction, showTrackMenu;
import '../shell/dock.dart';
import 'album_card.dart';
import 'artist_page.dart';
import 'artist_portrait.dart';
import 'library_controls.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Pre-artist hub (WA0010 grammar): the shallow stop between the
/// Artists index and the full artist page. Circular portrait,
/// name with a chevron into the deep page, Play / Shuffle, top
/// songs and the owned albums. Nothing here is a dead end: the
/// name chevron and the `...` menu both reach the full page.
class ArtistHubPage extends ConsumerStatefulWidget {
  final String artistName;

  const ArtistHubPage({super.key, required this.artistName});

  /// Same discipline as ArtistPage: never stack the same artist twice.
  static final Set<String> _open = {};

  static bool openIfAbsent(BuildContext context, String artistName) {
    if (_open.contains(artistName)) return false;
    ArchLog.i('nav', 'artist hub open: $artistName');
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ArtistHubPage(artistName: artistName)),
    );
    return true;
  }

  @override
  ConsumerState<ArtistHubPage> createState() => _ArtistHubPageState();
}

class _ArtistHubPageState extends ConsumerState<ArtistHubPage> {
  @override
  void initState() {
    super.initState();
    ArtistHubPage._open.add(widget.artistName);
  }

  @override
  void dispose() {
    ArtistHubPage._open.remove(widget.artistName);
    super.dispose();
  }

  Future<void> _play(List<Song> queue, Song song) async {
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(song, queue));
  }

  void _playAll(List<Song> songs) {
    if (songs.isEmpty) return;
    _play(songs, songs.first);
  }

  Future<void> _shuffleAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playShuffled(songs));
  }

  /// Hub albums carry the year when the tags know it, else the count.
  String _albumSubtitle(Album album) {
    final year = album.songs
        .map((s) => s.year)
        .firstWhere((y) => y > 0, orElse: () => 0);
    return year > 0 ? '$year' : '${album.songs.length} songs';
  }

  Future<void> _openMenu(BuildContext buttonContext, List<Song> songs) async {
    final value = await showTrackMenu(
      context: buttonContext,
      groups: [
        [
          const MenuAction(
            icon: CupertinoIcons.person,
            label: 'Open artist page',
            value: 'open',
          ),
          const MenuAction(
            icon: CupertinoIcons.shuffle,
            label: 'Shuffle',
            value: 'shuffle',
          ),
        ],
      ],
    );
    if (!mounted) return;
    switch (value) {
      case 'open':
        ArtistPage.openIfAbsent(context, widget.artistName);
        break;
      case 'shuffle':
        _shuffleAll(songs);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(songsProvider).value ?? [];
    final songs = all
        .where((s) => artistsOverlap(s.artist, widget.artistName))
        .toList();
    final albums =
        ref
            .watch(albumsProvider)
            .where((a) => artistsOverlap(a.artist, widget.artistName))
            .toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
    final followed = ref.watch(followedProvider).contains(widget.artistName);
    final rep = songs.isEmpty
        ? null
        : songs.firstWhere((s) => s.path.isNotEmpty, orElse: () => songs.first);
    final top = songs.take(5).toList();

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
                        const Spacer(),
                        LibraryCornerCluster(
                          leftIcon: followed
                              ? CupertinoIcons.star_fill
                              : CupertinoIcons.star,
                          leftColor: followed
                              ? archPink
                              : Theme.of(context).colorScheme.onSurface,
                          onLeft: () => ref
                              .read(followedProvider.notifier)
                              .toggle(widget.artistName),
                          onMenu: (ctx) => _openMenu(ctx, songs),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
                SliverToBoxAdapter(
                  child: Center(
                    child: ClipOval(
                      child: SizedBox(
                        width: 104,
                        height: 104,
                        child: ArtistPortrait(
                          name: widget.artistName,
                          song: rep,
                          size: 104,
                          fill: true,
                        ),
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 14)),
                SliverToBoxAdapter(
                  child: Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        ArtistPage.openIfAbsent(context, widget.artistName);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                widget.artistName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'ArchSerif',
                                  fontSize: 32,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.6,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              CupertinoIcons.chevron_right,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              size: 26,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 18)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: LibraryActionPill(
                            icon: CupertinoIcons.play_fill,
                            label: 'Play',
                            onTap: songs.isEmpty ? null : () => _playAll(songs),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: LibraryActionPill(
                            icon: CupertinoIcons.shuffle,
                            label: 'Shuffle',
                            onTap: songs.isEmpty
                                ? null
                                : () => _shuffleAll(songs),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 26)),
                if (songs.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 24,
                      ),
                      child: Text(
                        'No local songs for this artist yet.',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ),
                  )
                else ...[
                  const SliverToBoxAdapter(child: _SectionHead('Top songs')),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 196,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: top.length,
                        itemBuilder: (context, i) => Padding(
                          padding: EdgeInsets.only(
                            right: i == top.length - 1 ? 0 : 12,
                          ),
                          child: _TopSongCard(
                            song: top[i],
                            onTap: () => _play(songs, top[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (albums.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  const SliverToBoxAdapter(child: _SectionHead('Albums')),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 18,
                        mainAxisExtent:
                            (MediaQuery.sizeOf(context).width - 52) / 2 + 46,
                      ),
                      itemCount: albums.length,
                      itemBuilder: (context, i) => AlbumGridCard(
                        album: albums[i],
                        subtitle: _albumSubtitle(albums[i]),
                      ),
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 160)),
              ],
            ),
          ),
          const NowPlayingDock(),
        ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  final String title;

  const _SectionHead(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: 'ArchSerif',
          fontSize: 19,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Rail card, same geometry as the home rails: 140 cover, one-line
/// title and album. Tap plays the track and continues the artist.
class _TopSongCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _TopSongCard({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              height: 140,
              child: song.path.isNotEmpty
                  ? FileArtImage(
                      path: song.path,
                      albumId: song.albumId,
                      size: 130,
                      radius: 18,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(
                        CupertinoIcons.music_note,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 36,
                      ),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            Text(
              song.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
