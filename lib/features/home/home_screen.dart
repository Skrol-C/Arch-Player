import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/album_page.dart';
import '../library/artist_page.dart';
import '../library/library_providers.dart';
import '../library/playlist_page.dart';
import '../library/song_row.dart';
import '../needle/preview_play.dart';
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../profile/profile_pic.dart';
import '../profile/profile_screen.dart';
import '../shell/dock.dart';
import 'cover_color.dart';
import 'home_feed.dart';

/// Home: greeting + cover-first rails. Local rails (recently played,
/// top artists) lead; extension home feeds follow, one rail per
/// provider section. Every card does something real on tap.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(homeLocalProvider);
    final ext = ref.watch(homeExtensionProvider);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: DockScrollReporter(
        child: CustomScrollView(
          physics: const ClampingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(context)),
            const SliverToBoxAdapter(child: SizedBox(height: 4)),
            ...local.when(
              loading: () => const [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 300,
                    child: Center(
                      child: CircularProgressIndicator(
                          color: archPink, strokeWidth: 2),
                    ),
                  ),
                ),
              ],
              error: (e, _) => [
                SliverToBoxAdapter(child: _error(context, ref, '$e')),
              ],
              data: (d) => [
                if (d.deck.isNotEmpty)
                  SliverToBoxAdapter(child: _Deck(songs: d.deck)),
                if (d.deck.isNotEmpty)
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                for (var i = 0; i < d.rails.length; i++) ...[
                  SliverToBoxAdapter(
                      child: _rail(context, ref, d.rails[i], i)),
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                ],
                ...ext.when(
                  loading: () => const [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 120,
                        child: Center(
                          child: CircularProgressIndicator(
                              color: archPink, strokeWidth: 2),
                        ),
                      ),
                    ),
                  ],
                  error: (_, _) => const <Widget>[],
                  data: (rails) {
                    if (d.deck.isEmpty &&
                        d.rails.isEmpty &&
                        rails.isEmpty) {
                      return [SliverToBoxAdapter(child: _empty(context))];
                    }
                    return [
                      for (var i = 0; i < rails.length; i++) ...[
                        SliverToBoxAdapter(
                            child: _rail(
                                context, ref, rails[i], d.rails.length + i)),
                        const SliverToBoxAdapter(
                            child: SizedBox(height: 20)),
                      ],
                    ];
                  },
                ),
              ],
            ),
            // Dock clearance: last rail never hides under the pill.
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final h = DateTime.now().hour;
    final greet = h < 5
        ? 'Up late'
        : h < 12
            ? 'Good morning'
            : h < 18
                ? 'Good afternoon'
                : 'Good evening';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 64, 20, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              greet,
              style: const TextStyle(
                fontFamily: 'ArchSerif',
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const _HomeAvatar(),
        ],
      ),
    );
  }

  Widget _error(BuildContext context, WidgetRef ref, String detail) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Home is quiet right now.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => ref.invalidate(homeFeedProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Text(
          'Play something and Home fills in — recents, artists, and your providers\u2019 new releases land here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
        ),
      ),
    );
  }

  Widget _rail(
      BuildContext context, WidgetRef ref, HomeRail rail, int index) {
    if (rail.key == 'local-recent') {
      return _jumpBackIn(context, ref, rail, index);
    }
    if (rail.key == 'local-artists') {
      return _ArtistsRail(rail: rail);
    }
    // All-artist rails (Popular Artists, Hot Artist) get portraits;
    // everything else gets cover cards.
    final circular = rail.items.isNotEmpty &&
        rail.items.every((i) => i.type == 'artist');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _railHead(context, rail),
        const SizedBox(height: 10),
        SizedBox(
          height: circular ? 190 : 196,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: rail.items.length,
            itemBuilder: (context, i) {
              final item = rail.items[i];
              return CascadeIn(
                delayMs: (index * 40 + i * 30).clamp(0, 400),
                child: Padding(
                  padding: EdgeInsets.only(
                      right: i == rail.items.length - 1 ? 0 : 12),
                  child: circular
                      ? _PortraitCard(
                          item: item,
                          onTap: () => _tapItem(context, ref, rail, item),
                        )
                      : _coverCard(context, ref, rail, item),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _railHead(BuildContext context, HomeRail rail) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            rail.title,
            style: const TextStyle(
              fontFamily: 'ArchSerif',
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (rail.subtitle.isNotEmpty)
            Text(
              rail.subtitle,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
        ],
      ),
    );
  }

  /// Jump back in as a swipeable table: pages of song rows, YT
  /// Music style. Pages are balanced so the last one is never a
  /// single orphan. Tapping a row plays it and continues through
  /// the rail; nothing here is decorative.
  Widget _jumpBackIn(
      BuildContext context, WidgetRef ref, HomeRail rail, int index) {
    final songs = [
      for (final f in rail.items)
        if (f.song != null) f.song!,
    ];
    if (songs.isEmpty) return const SizedBox.shrink();
    const perPage = 3;
    final pageCount = (songs.length / perPage).ceil();
    final base = songs.length ~/ pageCount;
    final extra = songs.length % pageCount;
    final chunks = <List<Song>>[];
    var at = 0;
    for (var p = 0; p < pageCount; p++) {
      final n = base + (p < extra ? 1 : 0);
      chunks.add(songs.sublist(at, at + n));
      at += n;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _railHead(context, rail),
        const SizedBox(height: 6),
        _JumpPages(rail: rail, chunks: chunks),
      ],
    );
  }

  Widget _coverCard(
      BuildContext context, WidgetRef ref, HomeRail rail, FeedItem item) {
    return GestureDetector(
      onTap: () => _tapItem(context, ref, rail, item),
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _art(context, item, 140, 18),
            const SizedBox(height: 6),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700),
            ),
            if (item.artists.isNotEmpty)
              Text(
                item.artists,
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

  Widget _art(
      BuildContext context, FeedItem item, double size, double radius) {
    if (item.isLocal && item.song!.path.isNotEmpty) {
      return FileArtImage(
        path: item.song!.path,
        albumId: item.song!.albumId,
        size: size.toDouble(),
        radius: radius,
      );
    }
    if (item.coverUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CachedNetworkImage(
          imageUrl: item.coverUrl,
          width: size,
          height: size,
          memCacheWidth: 280,
          fit: BoxFit.cover,
          errorWidget: (ctx, _, _) => _artFallback(ctx, size, radius),
        ),
      );
    }
    return _artFallback(context, size, radius);
  }

  Widget _artFallback(BuildContext context, double size, double radius) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(CupertinoIcons.music_note,
          color: Theme.of(context).colorScheme.onSurfaceVariant, size: 36),
    );
  }

  /// Owned-album deep link: normalized title + shared artist wins
  /// a local AlbumPage with your files. Anything else stays remote.
  Album? _ownedAlbum(WidgetRef ref, String title, String artists) {
    final nt = normTitle(title);
    if (nt.isEmpty) return null;
    for (final a in ref.read(albumsProvider)) {
      if (normTitle(a.title) != nt) continue;
      if (artists.trim().isNotEmpty &&
          !artistsOverlap(a.artist, artists)) {
        continue;
      }
      return a;
    }
    return null;
  }

  Future<void> _tapItem(
      BuildContext context, WidgetRef ref, HomeRail rail, FeedItem item) async {
    HapticFeedback.selectionClick();
    if (item.isLocal && item.type == 'track') {
      final handler = ref.read(audioHandlerProvider);
      final queue = [
        for (final f in rail.items)
          if (f.song != null) f.song!,
      ];
      await playAndOpen(ref, context, () => handler.playSong(item.song!, queue));
      return;
    }
    if (item.type == 'artist' && item.name.isNotEmpty) {
      ArtistPage.openIfAbsent(context, item.name);
      return;
    }
    if (item.type == 'track' && item.providerId.isNotEmpty) {
      await playSearchPreview(
        ref,
        context,
        providerId: item.providerId,
        providerName: item.providerName,
        trackId: item.id,
        title: item.name,
        artist: item.artists,
        album: '',
        art: item.coverUrl,
        previewUrl: '',
      );
      return;
    }
    if (item.type == 'album' && item.id.isNotEmpty) {
      final owned = _ownedAlbum(ref, item.name, item.artists);
      if (owned != null && context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AlbumPage(album: owned)),
        );
        return;
      }
      PlaylistPage.open(
        context,
        providerId: item.providerId,
        providerName: item.providerName,
        id: item.id,
        name: item.name,
        art: item.coverUrl,
        artist: item.artists,
        kind: 'album',
      );
      return;
    }
    if (item.type == 'playlist' && item.providerId.isNotEmpty) {
      if (item.id.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nothing playable in ${item.name}')),
        );
        return;
      }
      PlaylistPage.open(
        context,
        providerId: item.providerId,
        providerName: item.providerName,
        id: item.id,
        name: item.name,
        art: item.coverUrl,
        kind: 'playlist',
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Nothing playable in ${item.name}')),
    );
  }
}

/// Home header avatar: the profile pic when set, the person mark
/// otherwise. Always opens Profile.
class _HomeAvatar extends ConsumerWidget {
  const _HomeAvatar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pic = ref.watch(profilePicProvider);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProfileScreen()),
        );
      },
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(19),
        ),
        clipBehavior: Clip.antiAlias,
        child: pic != null
            ? Image.file(
                File(pic),
                width: 38,
                height: 38,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  CupertinoIcons.person_crop_circle,
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 30,
                ),
              )
            : Icon(
                CupertinoIcons.person_crop_circle,
                color: Theme.of(context).colorScheme.onSurface,
                size: 30,
              ),
      ),
    );
  }
}

/// Spotlight deck: 5 dealt cards, swipeable with peeked edges. Tap
/// a card or Start listening and the queue runs the deck in order
/// from that card. User-driven swipes only — no autoplay — so
/// reduced-motion needs no special case.
class _Deck extends ConsumerStatefulWidget {
  final List<Song> songs;
  const _Deck({required this.songs});

  @override
  ConsumerState<_Deck> createState() => _DeckState();
}

class _DeckState extends ConsumerState<_Deck> {
  late final PageController _pages;
  int _visible = 0;

  @override
  void initState() {
    super.initState();
    _pages = PageController(viewportFraction: 0.78);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _play(int index) async {
    final songs = widget.songs;
    if (index < 0 || index >= songs.length) return;
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(
        ref, context, () => handler.playSong(songs[index], songs));
  }

  @override
  Widget build(BuildContext context) {
    final songs = widget.songs;
    // One extra page past the deck: the re-deal tile lives at the end
    // of the swipe, in Home, not in settings.
    final pageCount = songs.length + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 300,
          child: PageView.builder(
            controller: _pages,
            onPageChanged: (i) => setState(() => _visible = i),
            itemCount: pageCount,
            itemBuilder: (context, i) {
              if (i >= songs.length) return _shuffleTile(context);
              final s = songs[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => _play(i),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FileArtImage(
                          path: s.path,
                          albumId: s.albumId,
                          size: 600,
                          radius: 0,
                          fill: true,
                        ),
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.72),
                              ],
                              stops: const [0.45, 1.0],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 14,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.title.isEmpty ? 'Untitled' : s.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                s.artist.isEmpty
                                    ? 'Unknown artist'
                                    : s.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white
                                      .withValues(alpha: 0.85),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Positioned(
                          right: 12,
                          bottom: 12,
                          child: Icon(
                            CupertinoIcons.play_circle_fill,
                            color: Colors.white,
                            size: 44,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              for (var i = 0; i < pageCount; i++)
                Container(
                  width: i == _visible ? 18 : 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: i == _visible
                        ? archPink
                        : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  ),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _play(_visible.clamp(0, songs.length - 1)),
                icon: const Icon(CupertinoIcons.play_fill, size: 15),
                label: const Text('Start listening'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The end of the deck: a re-deal tile, not a song. Same house
  /// styling as the cards so the swipe never hits a dead end.
  Widget _shuffleTile(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          ref.read(deckReshuffleProvider.notifier).state++;
        },
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(CupertinoIcons.shuffle,
                  color: archPink, size: 44),
              const SizedBox(height: 10),
              const Text(
                'Re-deal',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Fresh five',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Swipeable table for Jump back in: pages of three song rows.
/// Tapping a row plays it and continues through the rail.
class _JumpPages extends ConsumerStatefulWidget {
  final HomeRail rail;
  final List<List<Song>> chunks;
  const _JumpPages({required this.rail, required this.chunks});

  @override
  ConsumerState<_JumpPages> createState() => _JumpPagesState();
}

class _JumpPagesState extends ConsumerState<_JumpPages> {
  late final PageController _pages;
  int _visible = 0;

  @override
  void initState() {
    super.initState();
    _pages = PageController(viewportFraction: 0.94);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _play(Song song, List<Song> queue) async {
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(song, queue));
  }

  @override
  Widget build(BuildContext context) {
    final currentId = ref.watch(currentSongProvider).value?.id;
    final songs = [
      for (final c in widget.chunks) ...c,
    ];
    return Column(
      children: [
        SizedBox(
          height: 258,
          child: PageView.builder(
            controller: _pages,
            onPageChanged: (i) => setState(() => _visible = i),
            itemCount: widget.chunks.length,
            itemBuilder: (context, p) {
              final chunk = widget.chunks[p];
              // No card behind the rows: dividers do the separating,
              // the rows sit straight on the page.
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var j = 0; j < chunk.length; j++) ...[
                      if (j > 0)
                        const Divider(
                          height: 1,
                          thickness: 1,
                          indent: 100,
                          endIndent: 20,
                          color: Color(0x140B0B0D),
                        ),
                      _JumpRow(
                        song: chunk[j],
                        isCurrent:
                            currentId != null && chunk[j].id == currentId,
                        onTap: () => _play(chunk[j], songs),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < widget.chunks.length; i++)
              Container(
                width: i == _visible ? 18 : 7,
                height: 7,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: i == _visible
                      ? archPink
                      : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Jump-back-in row: bigger art, bolder type, more air than the
/// library row. Home-only — SongRow stays untouched.
class _JumpRow extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;
  const _JumpRow(
      {required this.song, required this.isCurrent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 64,
                height: 64,
                child: FileArtImage(
                  path: song.path,
                  albumId: song.albumId,
                  size: 128,
                  radius: 0,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title.isEmpty ? 'Untitled' : song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? archPink : Theme.of(context).colorScheme.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    song.artist.isEmpty ? 'Unknown artist' : song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (isCurrent) NowBars(song: song),
            if (isCurrent) const SizedBox(width: 8),
            Text(
              fmtDuration(song.duration),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Your artists rail: bigger portraits, long-press springs one open
/// into their five most recent plays. True in-rail expansion —
/// siblings shift, nothing breaks. Four seconds of quiet and the
/// portrait reabsorbs the list with the same spring in reverse.
/// Only one artist open at a time.
/// Circular artist portrait shared by Your artists and all-artist
/// provider rails (Popular Artists, Hot Artist…). Tap opens the
/// artist page; long-press is the (currently hidden) fan-out.
class _PortraitCard extends StatelessWidget {
  final FeedItem item;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const _PortraitCard({
    required this.item,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    const size = 132.0;
    return GestureDetector(
      onTap: () {
        if (onTap != null) {
          HapticFeedback.selectionClick();
          onTap!();
        }
      },
      onLongPress: onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onLongPress!();
            },
      child: SizedBox(
        width: size,
        child: Column(
          children: [
            ClipOval(
              child: SizedBox(
                width: size,
                height: size,
                child: _portraitArt(context, item, size),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              displayArtists(item.name).isEmpty ? item.name : displayArtists(item.name),
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _portraitArt(BuildContext context, FeedItem item, double size) {
    if (item.song != null && item.song!.path.isNotEmpty) {
      return FileArtImage(
        path: item.song!.path,
        albumId: item.song!.albumId,
        size: size * 2,
        radius: 0,
      );
    }
    if (item.coverUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: item.coverUrl,
        width: size,
        height: size,
        memCacheWidth: 280,
        fit: BoxFit.cover,
        errorWidget: (ctx, _, _) => Container(
          color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
          child: Icon(CupertinoIcons.music_note,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 44),
        ),
      );
    }
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(CupertinoIcons.music_note,
          color: Theme.of(context).colorScheme.onSurfaceVariant, size: 44),
    );
  }
}

class _ArtistsRail extends ConsumerStatefulWidget {
  final HomeRail rail;
  const _ArtistsRail({required this.rail});

  @override
  ConsumerState<_ArtistsRail> createState() => _ArtistsRailState();
}

class _ArtistsRailState extends ConsumerState<_ArtistsRail>
    with SingleTickerProviderStateMixin {
  // Expansion fan-out, hidden for now. Flip to bring back the
  // long-press spring-out + reabsorb choreography.
  static const _expansionEnabled = false;
  String? _expanded;
  bool _closing = false;
  List<Song> _fanSongs = const [];
  final _colors = <int, Color>{};
  int _washGen = 0;  // Nullable on purpose: after a hot reload the retained state object
  // predates this field; null means "no choreography", never a crash.
  // Fresh states always get a controller in initState.
  AnimationController? _dive;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _dive = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _dive?.dispose();
    super.dispose();
  }

  void _expand(String name) {
    HapticFeedback.mediumImpact();
    _timer?.cancel();
    _dive?.stop();
    if (_dive != null) _dive!.value = 0;
    setState(() {
      _expanded = name;
      _closing = false;
    });
    _arm();
  }

  void _switchTo(String name) {
    _closeInstant();
    _expand(name);
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), () {
      if (mounted) _collapse();
    });
  }

  /// Choreographed reabsorb: the card shrinks while rows arc-dive
  /// into the portrait in reverse order. Reduced motion and song-tap
  /// close instantly.
  void _collapse() {
    if (_expanded == null || _closing) return;
    final dive = _dive;
    if (dive == null || Motion.reduced(context)) {
      _closeInstant();
      return;
    }
    setState(() => _closing = true);
    final gen = ++_washGen;
    dive.forward(from: 0).then((_) {
      if (!mounted || gen != _washGen) return;
      setState(() {
        _expanded = null;
        _closing = false;
      });
    });
  }

  void _closeInstant() {
    _timer?.cancel();
    _washGen++;
    _dive?.stop();
    if (!mounted) return;
    setState(() {
      _expanded = null;
      _closing = false;
    });
  }

  Future<void> _warmColors(List<Song> songs) async {
    for (final s in songs) {
      if (_colors.containsKey(s.id)) continue;
      final c = await dominantCoverColor(s);
      if (c != null && mounted) setState(() => _colors[s.id] = c);
    }
  }

  Future<void> _play(List<Song> queue, Song song) async {
    _timer?.cancel();
    _washGen++;
    _dive?.stop();
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(song, queue));
    if (!mounted) return;
    setState(() {
      _expanded = null;
      _closing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            widget.rail.title,
            style: const TextStyle(
              fontFamily: 'ArchSerif',
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (widget.rail.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              widget.rail.subtitle,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        const SizedBox(height: 10),
        SizedBox(
          height: 204,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: widget.rail.items.length,
            itemBuilder: (context, i) {
              final item = widget.rail.items[i];
              final open = _expanded == item.name;
              return Padding(
                padding: EdgeInsets.only(
                    right: i == widget.rail.items.length - 1 ? 0 : 12),
                child: open && _expansionEnabled
                    ? _expandedCard(context, item)
                    : _portraitCard(item),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _portraitCard(FeedItem item) {
    return _PortraitCard(
      item: item,
      onLongPress:
          _expansionEnabled ? () => _expand(item.name) : null,
      onTap: () {
        // An open expansion hijacks taps: move it instead of leaving.
        if (_expanded != null && _expanded != item.name) {
          _switchTo(item.name);
        } else {
          ArtistPage.openIfAbsent(context, item.name);
        }
      },
    );
  }

  Widget _expandedCard(BuildContext context, FeedItem item) {
    return GestureDetector(
      onTap: _collapse,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutBack,
        width: _closing ? 132 : 320,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Wash tint driven by the dive clock itself: each row
                // flashes its own cover color as it lands, pulsing out.
                // No timers — perfectly in step with the dives.
                SizedBox(
                  width: 112,
                  height: 112,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      ClipOval(
                        child: SizedBox(
                          width: 112,
                          height: 112,
                          child: item.song != null &&
                                  item.song!.path.isNotEmpty
                              ? FileArtImage(
                                  path: item.song!.path,
                                  albumId: item.song!.albumId,
                                  size: 224,
                                  radius: 0,
                                )
                              : Container(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                      CupertinoIcons.music_note,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      size: 40),
                                ),
                        ),
                      ),
                      _WashTint(
                        flight: _dive,
                        order: [..._fanSongs].reversed.toList(),
                        colors: _colors,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // OverflowBox, not Expanded flex: the shrinking card
                // clips instead of throwing a Flex overflow.
                Expanded(
                  child: ClipRect(
                    child: OverflowBox(
                      maxWidth: 220,
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                          width: 220, child: _fanList(item)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fanList(FeedItem item) {
    final recent = ref.watch(artistRecentProvider(item.name));
    return recent.when(
      loading: () => const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              color: archPink, strokeWidth: 2),
        ),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (songs) {
        // Stash for the collapse order; warm cover colors now so the
        // wash steps never wait on a decode mid-choreography.
        _fanSongs = songs;
        unawaited(_warmColors(songs));
        final diving = _closing;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < songs.length; i++)
              CascadeIn(
                delayMs: (i * 45).clamp(0, 400),
                child: _DiveRow(
                  flight: _dive,
                  // Reverse cascade: last row lands first.
                  start: (songs.length - 1 - i) * 0.09,
                  arc: (i - (songs.length - 1) / 2) * 34,
                  diving: diving,
                  child: _FanRow(
                    song: songs[i],
                    onTap: () => _play(songs, songs[i]),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One dive leg: while the collapse flight runs, the row arcs left
/// toward the portrait (bowed upward mid-flight), shrinks and fades.
/// Idle it is an identity wrapper — entrance stays CascadeIn's job.
class _DiveRow extends StatelessWidget {
  final Animation<double>? flight;
  final double start;
  final double arc;
  final bool diving;
  final Widget child;
  const _DiveRow({
    required this.flight,
    required this.start,
    required this.arc,
    required this.diving,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final f = flight;
    if (!diving || f == null) return child;
    return AnimatedBuilder(
      animation: f,
      builder: (_, _) {
        final p = ((f.value - start) / 0.5).clamp(0.0, 1.0);
        if (p <= 0) return child;
        final e = Curves.easeIn.transform(p);
        final lift = math.sin(p * math.pi) * 18;
        return Opacity(
          opacity: 1 - p,
          child: Transform.translate(
            offset: Offset(-190 * e, -arc * e - lift),
            child: Transform.scale(
              scale: 1 - 0.65 * p,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Wash tint driven by the same dive clock as the rows: as each row
/// lands (reverse order), the portrait flashes that song's cover
/// color, pulsing out. No timers — color and motion share one clock,
/// so the stagger is the pulse.
class _WashTint extends StatelessWidget {
  final Animation<double>? flight;
  final List<Song> order;
  final Map<int, Color> colors;
  const _WashTint(
      {required this.flight, required this.order, required this.colors});

  @override
  Widget build(BuildContext context) {
    final f = flight;
    if (f == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: f,
      builder: (_, _) {
        final v = f.value;
        Color? c;
        var alpha = 0.0;
        for (var k = 0; k < order.length; k++) {
          final land = k * 0.09 + 0.5;
          if (v < land) break;
          final recency = v - land;
          if (recency > 0.45) continue;
          final cc = colors[order[k].id];
          if (cc != null) {
            c = cc;
            alpha = (1 - recency / 0.45) * 0.55;
          }
        }
        if (c == null || alpha <= 0.01) return const SizedBox.shrink();
        return ClipOval(
          child: Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              color: c.withValues(alpha: alpha),
              boxShadow: [
                BoxShadow(
                    color: c.withValues(alpha: alpha), blurRadius: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One fan-out row: small art, single-line title. Tapping plays it
/// and continues through the other four in recency order.
class _FanRow extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  const _FanRow({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 32,
                height: 32,
                child: song.path.isNotEmpty
                    ? FileArtImage(
                        path: song.path,
                        albumId: song.albumId,
                        size: 64,
                        radius: 0,
                      )
                    : Container(
                        color: Theme.of(context).colorScheme.surface,
                        child: Icon(CupertinoIcons.music_note,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            size: 16),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                song.title.isEmpty ? 'Untitled' : song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            Icon(CupertinoIcons.play_fill,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 14),
          ],
        ),
      ),
    );
  }
}
