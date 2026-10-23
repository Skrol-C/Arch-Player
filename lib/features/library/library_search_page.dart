import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../shell/dock.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'library_chrome.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Library search: the pill search's shape without providers. One
/// entry point (the library header), grouped results like Search,
/// sort riding in the bar. Own query state — leaving never pollutes
/// anything behind it.
class LibrarySearchPage extends ConsumerStatefulWidget {
  const LibrarySearchPage({super.key});

  @override
  ConsumerState<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

enum _LocalSort { title, artist, recent }

class _LibrarySearchPageState extends ConsumerState<LibrarySearchPage> {
  final _controller = TextEditingController();
  var _query = '';
  var _sort = _LocalSort.title;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = v.trim().toLowerCase());
    });
  }

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(songsProvider).value ?? [];
    final current = ref.watch(currentSongProvider).value;
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear = collapsed
        ? 120.0
        : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);
    final q = _query;
    final matched = q.isEmpty
        ? const <Song>[]
        : songs.where((s) {
            return s.title.toLowerCase().contains(q) ||
                s.artist.toLowerCase().contains(q) ||
                s.album.toLowerCase().contains(q);
          }).toList();
    var ordered = matched;
    switch (_sort) {
      case _LocalSort.title:
        ordered = [...matched]
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
      case _LocalSort.artist:
        ordered = [...matched]
          ..sort((a, b) {
            final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
            return c != 0
                ? c
                : a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
      case _LocalSort.recent:
        ordered = [...matched]
          ..sort((a, b) => b.addedSecs.compareTo(a.addedSecs));
    }
    final artists = _matchArtists(songs, q);
    final albums = _matchAlbums(songs, q);
    return Scaffold(
      backgroundColor: paper,
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
                              color: paperRaised,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: const Icon(
                              CupertinoIcons.chevron_left,
                              color: ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SearchBar(
                            controller: _controller,
                            hintText: 'Search library',
                            backgroundColor: const WidgetStatePropertyAll(
                              paperRaised,
                            ),
                            elevation: const WidgetStatePropertyAll(0),
                            onChanged: _onChanged,
                            trailing: [
                              IconButton(
                                tooltip: 'Sort',
                                icon: const Icon(
                                  CupertinoIcons.arrow_up_down,
                                  color: inkDim,
                                  size: 20,
                                ),
                                onPressed: () async {
                                  final picked =
                                      await showLibrarySort<_LocalSort>(
                                        context: context,
                                        current: _sort,
                                        options: const [
                                          (
                                            label: 'Title',
                                            value: _LocalSort.title,
                                          ),
                                          (
                                            label: 'Artist',
                                            value: _LocalSort.artist,
                                          ),
                                          (
                                            label: 'Recently added',
                                            value: _LocalSort.recent,
                                          ),
                                        ],
                                      );
                                  if (picked != null && mounted) {
                                    setState(() => _sort = picked);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                if (q.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 48),
                      child: Text(
                        'Songs, artists and albums on this phone — no providers, no waiting.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: inkDim, height: 1.5),
                      ),
                    ),
                  )
                else if (ordered.isEmpty && artists.isEmpty && albums.isEmpty)
                  const SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'Nothing here matches.',
                          style: TextStyle(color: inkDim),
                        ),
                      ),
                    ),
                  )
                else ...[
                  if (ordered.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: _SectionHead(title: 'Songs'),
                    ),
                    SliverList.builder(
                      itemCount: ordered.length,
                      itemBuilder: (context, i) {
                        final s = ordered[i];
                        final isCurrent = current?.id == s.id;
                        return SongRow(
                          song: s,
                          isCurrent: isCurrent,
                          onTap: () => _play(ref, context, s, ordered),
                        );
                      },
                    ),
                  ],
                  if (artists.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: _SectionHead(title: 'Artists'),
                    ),
                    SliverList.builder(
                      itemCount: artists.length,
                      itemBuilder: (context, i) {
                        final a = artists[i];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 4,
                          ),
                          leading: ClipOval(
                            child: SizedBox(
                              width: 52,
                              height: 52,
                              child: a.cover.path.isNotEmpty
                                  ? FileArtImage(
                                      path: a.cover.path,
                                      albumId: a.cover.albumId,
                                      size: 104,
                                      radius: 0,
                                    )
                                  : Container(
                                      color: paperRaised,
                                      child: const Icon(
                                        CupertinoIcons.person_fill,
                                        color: inkDim,
                                      ),
                                    ),
                            ),
                          ),
                          title: Text(
                            a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${a.count} song${a.count == 1 ? '' : 's'}',
                            style: const TextStyle(color: inkDim),
                          ),
                          trailing: const Icon(
                            CupertinoIcons.chevron_right,
                            color: inkDim,
                            size: 18,
                          ),
                          onTap: () => ArtistPage.openIfAbsent(context, a.name),
                        );
                      },
                    ),
                  ],
                  if (albums.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: _SectionHead(title: 'Albums'),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 20,
                          mainAxisExtent:
                              (MediaQuery.sizeOf(context).width - 56) / 2 +
                              46, // measured, not ratio
                        ),
                        itemCount: albums.length,
                        itemBuilder: (context, i) {
                          final a = albums[i];
                          return GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => AlbumPage(album: a.album),
                                ),
                              );
                            },
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: FileArtImage(
                                    path: a.album.songs.first.path,
                                    albumId: a.album.songs.first.albumId,
                                    fill: true,
                                    radius: 16,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  a.album.title,
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  a.album.artist,
                                  maxLines: 1,
                                  style: const TextStyle(
                                    color: inkDim,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
                SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
              ],
            ),
          ),
          const NowPlayingDock(),
        ],
      ),
    );
  }

  Future<void> _play(
    WidgetRef ref,
    BuildContext context,
    Song song,
    List<Song> queue,
  ) async {
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(song, queue));
  }

  /// Artists matching the query, most-played first. Split-aware:
  /// collaborations credit every slot.
  List<({String name, int count, Song cover})> _matchArtists(
    List<Song> songs,
    String q,
  ) {
    if (q.isEmpty) return const [];
    final counts = <String, ({String name, int count, Song cover})>{};
    for (final s in songs) {
      if (!s.title.toLowerCase().contains(q) &&
          !s.artist.toLowerCase().contains(q) &&
          !s.album.toLowerCase().contains(q)) {
        continue;
      }
      for (final a in splitArtists(s.artist)) {
        final key = a.trim().toLowerCase();
        if (key.isEmpty || isUnknownSlot(a)) continue;
        final prev = counts[key];
        counts[key] = (
          name: a.trim(),
          count: (prev?.count ?? 0) + 1,
          cover: prev?.cover ?? s,
        );
      }
    }
    final out = counts.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  /// Albums with any matching song, most matches first.
  List<({Album album, int count})> _matchAlbums(List<Song> songs, String q) {
    if (q.isEmpty) return const [];
    final byTitle = <String, List<Song>>{};
    for (final s in songs) {
      if (!s.title.toLowerCase().contains(q) &&
          !s.artist.toLowerCase().contains(q) &&
          !s.album.toLowerCase().contains(q)) {
        continue;
      }
      if (s.album.trim().isEmpty || isUnknownSlot(s.album)) continue;
      byTitle.putIfAbsent(normTitle(s.album), () => []).add(s);
    }
    final out = <({Album album, int count})>[];
    for (final entry in byTitle.entries) {
      final list = entry.value;
      list.sort((a, b) => a.title.compareTo(b.title));
      out.add((
        album: Album(
          key: entry.key,
          title: list.first.album,
          artist: list.first.artist,
          songs: list,
        ),
        count: list.length,
      ));
    }
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }
}

class _SectionHead extends StatelessWidget {
  final String title;
  const _SectionHead({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
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
