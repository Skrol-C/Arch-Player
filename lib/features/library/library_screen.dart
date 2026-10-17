import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/art_tone.dart';
import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'artist_page.dart';
import 'folder_sheet.dart';
import 'library_providers.dart';
import 'shelves.dart';
import 'song_row.dart';
import '../player/format_marks.dart';
import '../player/morph_icon.dart';
import '../player/track_menu.dart';
import '../shell/dock.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider);
    return songs.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator(color: archPink)),
      ),
      error: (e, _) {
        ArchLog.e('library', 'scan failed: $e');
        return Scaffold(body: Center(child: Text('Scan failed: $e')));
      },
      data: (_) => const _LibraryBody(),
    );
  }
}

class _LibraryBody extends ConsumerWidget {
  const _LibraryBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(libraryTabProvider);
    final view = ref.watch(libraryViewProvider);
    final visible = ref.watch(visibleSongsProvider);
    final current = ref.watch(currentSongProvider).value;
    // Clearance follows the docked unit so content never slides
    // under it: collapsed unit is short, mini + pill is tall.
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear = collapsed
        ? 120.0
        : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 64)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                FocalEntrance(
                  child: Text(
                    'Library',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    builder: (_) => const FolderSheet(),
                  ),
                  icon: const Icon(Icons.folder_rounded),
                  color: ink,
                  tooltip: 'Folders',
                ),
                IconButton(
                  onPressed: () {
                    final v = ref.read(libraryViewProvider);
                    ref.read(libraryViewProvider.notifier).state =
                        v == ViewMode.grid ? ViewMode.list : ViewMode.grid;
                  },
                  icon: Icon(
                    view == ViewMode.grid
                        ? Icons.view_list_rounded
                        : Icons.grid_view_rounded,
                  ),
                  color: ink,
                  tooltip: 'Grid / list',
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SearchBar(
              hintText: 'Search songs, artists, albums',
              backgroundColor: const WidgetStatePropertyAll(paperRaised),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: (q) =>
                  ref.read(libraryQueryProvider.notifier).state = q,
            ),
          ),
        ),
        SliverToBoxAdapter(child: _SortRow()),
        SliverToBoxAdapter(child: _TabPills()),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        const SliverToBoxAdapter(child: Shelves()),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        if (visible.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'No songs - check Folders.',
                style: TextStyle(color: inkDim),
              ),
            ),
          )
        else if (tab == LibraryTab.songs)
          view == ViewMode.grid
              ? _SongGrid(currentId: current?.id)
              : _SongList(currentId: current?.id)
        else if (tab == LibraryTab.albums)
          _AlbumGrid(currentId: current?.id)
        else
          const _ArtistList(),
        SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
      ],
    );
  }
}

class _SortRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(librarySortProvider);
    Widget chip(String label, SortOrder order) => FilterChip(
      label: Text(label),
      selected: sort == order,
      selectedColor: archPink.withValues(alpha: 0.15),
      checkmarkColor: archPink,
      onSelected: (_) => ref.read(librarySortProvider.notifier).state = order,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        children: [
          chip('Title', SortOrder.title),
          chip('Artist', SortOrder.artist),
          chip('Recent', SortOrder.recent),
        ],
      ),
    );
  }
}

class _TabPills extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(libraryTabProvider);
    Widget pill(String label, LibraryTab t) {
      final selected = tab == t;
      return GestureDetector(
        onTap: () => ref.read(libraryTabProvider.notifier).state = t,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? archPink : paperRaised,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          pill('Songs', LibraryTab.songs),
          const SizedBox(width: 8),
          pill('Albums', LibraryTab.albums),
          const SizedBox(width: 8),
          pill('Artists', LibraryTab.artists),
        ],
      ),
    );
  }
}

Future<void> _tapToPlay(
  WidgetRef ref,
  BuildContext context,
  Song song,
  List<Song> queue,
) async {
  final handler = ref.read(audioHandlerProvider);
  await playAndOpen(ref, context, () => handler.playSong(song, queue));
}

class _SongList extends ConsumerWidget {
  final int? currentId;
  const _SongList({required this.currentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(visibleSongsProvider);
    return SliverList.builder(
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final song = visible[i];
        return SongRow(
          song: song,
          isCurrent: song.id == currentId,
          onTap: () => _tapToPlay(ref, context, song, visible),
        );
      },
    );
  }
}

class _SongGrid extends ConsumerWidget {
  final int? currentId;
  const _SongGrid({required this.currentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(visibleSongsProvider);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          childAspectRatio: 0.78,
        ),
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final song = visible[i];
          final selected = song.id == currentId;
          return GestureDetector(
            onTap: () => _tapToPlay(ref, context, song, visible),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: selected
                          ? Border.all(color: archPink, width: 2)
                          : null,
                    ),
                    child: FileArtImage(
                      path: song.path,
                      albumId: song.albumId,
                      fill: true,
                      radius: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  song.title,
                  maxLines: 1,
                  style: TextStyle(
                    color: selected ? archPink : ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  style: const TextStyle(color: inkDim, fontSize: 13),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AlbumGrid extends ConsumerWidget {
  final int? currentId;
  const _AlbumGrid({required this.currentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(albumsProvider);
    if (albums.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Text('No albums match.', style: TextStyle(color: inkDim)),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          childAspectRatio: 0.78,
        ),
        itemCount: albums.length,
        itemBuilder: (context, i) {
          final album = albums[i];
          return GestureDetector(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => AlbumPage(album: album))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: FileArtImage(
                    path: album.songs.first.path,
                    albumId: album.songs.first.albumId,
                    fill: true,
                    radius: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  album.title,
                  maxLines: 1,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  album.artist,
                  maxLines: 1,
                  style: const TextStyle(color: inkDim, fontSize: 13),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A real album page: big art hero, voiced title, tappable artist,
/// Play + shuffle, indexed tracklist with per-row menus. Reached from
/// grids, featured card, gallery tiles, Popular overflow, and track
/// menus - never a dead tap, never a bare list.
/// One displayed album row: a provider-resolved track plus its
/// owned match (null = listed but not on this phone).
class _DisplayTrack {
  final int position;
  final String title;
  final int durationSecs;
  final Song? song;

  const _DisplayTrack({
    required this.position,
    required this.title,
    required this.durationSecs,
    required this.song,
  });
}

/// Full-bleed album hero: art fills the expanded bar edge to edge,
/// voice title + pink artist live ON it, the melt ends in paper.
/// Same collapse language as the artist hero (melt scrim, status
/// flip, pinned title, glass back/more) - one app, not two.
/// No album wordmarks exist in our sources (fanart serves covers +
/// cdart only), so the title stays typographic in our voice.
class _AlbumHero extends ConsumerWidget {
  final String title;
  final String artist;
  final int albumId;
  final VoidCallback onBack;
  final VoidCallback onMore;
  final VoidCallback onArtist;

  /// Page-shared wash: bar background and melt target. Reported back
  /// up via [onWash] once the cover tone resolves.
  final Color wash;
  final ValueChanged<Color>? onWash;

  static const _expanded = 440.0;

  const _AlbumHero({
    required this.title,
    required this.artist,
    required this.albumId,
    required this.onBack,
    required this.onMore,
    required this.onArtist,
    required this.wash,
    this.onWash,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topPad = MediaQuery.paddingOf(context).top;
    final hasArt = albumId > 0;
    final voice = artistVoiceOf(title);
    // Report the resolved tone once per cover: the page eases onto
    // it and hero, bar and body share one uniform color.
    final palette = ref.watch(albumPaletteProvider(albumId)).value;
    if (palette != null) {
      final toneWash = ArtTone.pageWashOf(palette.wash);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onWash?.call(toneWash);
      });
    }
    // Voice title in the cover's vibrant pick (white when the
    // vibrant sits too close to its own backdrop to read): words
    // carry color, not just shadow.
    var titleColor = hasArt ? Colors.white : ink;
    if (hasArt && palette != null) {
      final vibrant = palette.vibrant;
      final close =
          (vibrant.computeLuminance() - palette.photoLum).abs() < 0.25;
      if (!close) titleColor = vibrant;
    }
    return SliverAppBar(
      expandedHeight: _expanded,
      pinned: true,
      stretch: !Motion.reduced(context),
      backgroundColor: wash,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: LiquidGlassLens(
          style: ArchGlass.circle(radius: 24),
          child: IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: ink),
          ),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: LiquidGlassLens(
            style: ArchGlass.circle(radius: 24),
            child: IconButton(
              onPressed: onMore,
              icon: const Icon(CupertinoIcons.ellipsis, color: ink),
            ),
          ),
        ),
      ],
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final collapse =
              ((_expanded - constraints.maxHeight) /
                      (_expanded - (kToolbarHeight + topPad)))
                  .clamp(0.0, 1.0);
          // White status icons over art, dark once collapsed onto paper.
          final overlay = collapse > 0.5
              ? SystemUiOverlayStyle.dark.copyWith(
                  statusBarColor: Colors.transparent,
                )
              : SystemUiOverlayStyle.light.copyWith(
                  statusBarColor: Colors.transparent,
                );
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: overlay,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasArt)
                  AlbumArt(
                    albumId: albumId,
                    fill: true,
                    radius: 0,
                    detail: true,
                  )
                else
                  Container(
                    color: paperRaised,
                    child: const Icon(
                      Icons.album_outlined,
                      color: inkDim,
                      size: 96,
                    ),
                  ),
                // Melt pinned to the hero bottom, ends in the
                // shared wash: hero and body agree, no edge by
                // construction. Kept modest: the titles and meta
                // live on art and wash, never inside the fade.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 240,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.0, 0.4, 0.7, 1.0],
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.24),
                          wash,
                        ],
                      ),
                    ),
                  ),
                ),
                // Collapsed toolbar title fades in as the hero
                // titles fade out.
                Positioned(
                  top: topPad + 12,
                  left: 64,
                  right: 64,
                  child: Opacity(
                    opacity: collapse,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 56,
                  child: Opacity(
                    opacity: 1 - collapse,
                    child: Column(
                      children: [
                        FocalEntrance(
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: voice,
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: voiceSpacing(voice),
                              color: titleColor,
                              shadows: hasArt
                                  ? const [
                                      Shadow(
                                        color: Colors.black45,
                                        blurRadius: 16,
                                        offset: Offset(0, 2),
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: onArtist,
                          child: Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: archPink,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              shadows: hasArt
                                  ? const [
                                      Shadow(
                                        color: Colors.black45,
                                        blurRadius: 10,
                                        offset: Offset(0, 1),
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AlbumPage extends ConsumerStatefulWidget {
  final Album album;
  const AlbumPage({super.key, required this.album});

  @override
  ConsumerState<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends ConsumerState<AlbumPage> {
  /// Full-bleed page tint target, reported by the hero once the
  /// cover tone lands. Plain nullable field: no `late`, no ticker,
  /// so a hot reload can never strand it. Same pattern as the
  /// artist page - one app, one wash discipline.
  Color? _washTarget;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final current = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    final songs = album.songs;
    // Mount footprint: proves which build is on the phone and what
    // data arrived. Silence here means the route never built.
    ArchLog.i('nav', 'album page: ${album.title} (${songs.length} tracks)');
    // Empty can technically arrive (stale queue entry, moved files):
    // an explicit empty state, never a blank page or a crash on
    // songs.first.
    if (songs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Album')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.album_outlined, color: inkDim, size: 64),
              const SizedBox(height: 12),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'No songs found for this album.',
                style: TextStyle(color: inkDim),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text(
                  'Go back',
                  style: TextStyle(
                    color: archPink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    Future<void> play(bool shuffleFirst) async {
      final handler = ref.read(audioHandlerProvider);
      // Fire-and-forget: shuffle applies to the live player while the
      // guarded entry below owns the context across its own awaits.
      if (shuffleFirst) unawaited(handler.setShuffleEnabled(true));
      await playAndOpen(
        ref,
        context,
        () => handler.playSong(songs.first, songs),
      );
    }

    final total = songs.fold(Duration.zero, (sum, s) => sum + s.duration);
    // Uniform format: every track the same family (and known) earns
    // the chip. Mixed albums get no chip - the absence says mixed.
    AudioFormat? uniform;
    {
      final first = formatOf(songs.first.path);
      final same =
          first != AudioFormat.unknown &&
          songs.every((s) => formatOf(s.path) == first);
      if (same) uniform = first;
    }
    // Year from the first track that carries one. Zero = unknown,
    // omitted silently, never placeholder.
    var year = 0;
    for (final s in songs) {
      if (s.year > 0) {
        year = s.year;
        break;
      }
    }
    // Pause-aware play: when this album is what's sounding, the pill
    // offers pause instead of a redundant restart.
    final isThis = current != null && songs.any((s) => s.id == current.id);
    final showPause = isThis && playing;
    final losslessCount = songs
        .where((s) => formatLossless(formatOf(s.path)))
        .length;
    // Display tracklist: provider-resolved full listing when the
    // world knows this album, else owned-only. Owned rows match by
    // the shared identity discipline (title + duration window).
    final albumKey =
        '${album.artist.toLowerCase()}\x00${album.title.toLowerCase()}';
    final resolved = ref.watch(albumTracklistProvider(albumKey)).value ?? [];
    final genres = ref.watch(albumGenresProvider(albumKey)).value ?? [];
    final byTitle = <String, List<Song>>{};
    for (final s in songs) {
      byTitle.putIfAbsent(normTitle(s.title), () => []).add(s);
    }
    Song? ownedFor(AlbumTrack t) {
      final cands = byTitle[normTitle(t.title)];
      if (cands == null || cands.isEmpty) return null;
      if (t.durationSecs <= 0) return cands.first;
      for (final s in cands) {
        if (durClose(s.duration.inSeconds, t.durationSecs)) return s;
      }
      return null;
    }

    final displayTracks = resolved.isNotEmpty
        ? [
            for (final t in resolved)
              _DisplayTrack(
                position: t.position,
                title: t.title,
                durationSecs: t.durationSecs,
                song: ownedFor(t),
              ),
          ]
        : [
            for (var i = 0; i < songs.length; i++)
              _DisplayTrack(
                position: i + 1,
                title: songs[i].title,
                durationSecs: songs[i].duration.inSeconds,
                song: songs[i],
              ),
          ];

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        begin: ArtTone.pageWashOf(null),
        end: _washTarget ?? ArtTone.pageWashOf(null),
      ),
      duration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      builder: (context, wash, _) {
        final page = wash ?? ArtTone.pageWashOf(null);
        return Scaffold(
          backgroundColor: page,
          body: DockScrollReporter(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomScrollView(
                  slivers: [
                    // Full-bleed hero, one app with the artist page: art
                    // fills the expanded bar edge to edge, titles live
                    // ON it, the melt ends in the shared wash. No cut,
                    // no duplicated titles below.
                    _AlbumHero(
                      title: album.title,
                      artist: album.artist,
                      albumId: songs.first.albumId,
                      wash: page,
                      onWash: (c) {
                        if (!mounted || c == _washTarget) return;
                        setState(() => _washTarget = c);
                      },
                      onBack: () => Navigator.of(context).maybePop(),
                      onMore: () => _openAlbumMenu(ref, context, play),
                      onArtist: () =>
                          ArtistPage.openIfAbsent(context, album.artist),
                    ),
                    SliverToBoxAdapter(
                      // Content sits below the art: titles live in the
                      // hero, meta and actions open the body. Nothing
                      // hides inside the melt.
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                        child: Column(
                          children: [
                            // Dot meta: counts always, year + uniform
                            // chip only when the data earns them.
                            Wrap(
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 6,
                              children: [
                                Text(
                                  '${songs.length} song${songs.length == 1 ? '' : 's'} - ${fmtDuration(total)}',
                                  style: const TextStyle(color: inkDim),
                                ),
                                if (year > 0)
                                  Text(
                                    '- $year',
                                    style: const TextStyle(color: inkDim),
                                  ),
                                if (genres.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: ink.withValues(alpha: 0.16),
                                      ),
                                    ),
                                    child: Text(
                                      genres.first.toUpperCase(),
                                      style: const TextStyle(
                                        color: inkDim,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                if (uniform != null)
                                  FormatChip(path: songs.first.path),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    HapticFeedback.mediumImpact();
                                    if (showPause) {
                                      ref.read(audioHandlerProvider).pause();
                                    } else {
                                      play(false);
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 40,
                                      vertical: 14,
                                    ),
                                    decoration: const BoxDecoration(
                                      color: archPink,
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(28),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        MorphIcon(
                                          iconKey: showPause,
                                          child: Icon(
                                            showPause
                                                ? CupertinoIcons.pause_fill
                                                : CupertinoIcons.play_fill,
                                            color: Colors.white,
                                            size: 24,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          showPause ? 'Pause' : 'Play',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 17,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                GestureDetector(
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    play(true);
                                  },
                                  child: Container(
                                    width: 52,
                                    height: 52,
                                    decoration: BoxDecoration(
                                      color: paperRaised,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: ink.withValues(alpha: 0.08),
                                      ),
                                    ),
                                    child: const Icon(
                                      CupertinoIcons.shuffle_medium,
                                      color: ink,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: displayTracks.length,
                      itemBuilder: (context, i) {
                        final t = displayTracks[i];
                        final owned = t.song;
                        if (owned == null) {
                          // Listed but not on this phone: dimmed, honest,
                          // inert except a pointer toward Needle.
                          return CascadeIn(
                            delayMs: (i + 1).clamp(1, 10) * 30,
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 2,
                              ),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${t.title} is not on this phone yet - Needle will fetch it',
                                    ),
                                  ),
                                );
                              },
                              leading: SizedBox(
                                width: 30,
                                child: Text(
                                  '${t.position}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: inkDim,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              title: Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: ink.withValues(alpha: 0.75),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: const Text(
                                'Not on this device',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: inkDim, fontSize: 13),
                              ),
                              trailing: t.durationSecs > 0
                                  ? Text(
                                      fmtDuration(
                                        Duration(seconds: t.durationSecs),
                                      ),
                                      style: const TextStyle(color: inkDim),
                                    )
                                  : null,
                            ),
                          );
                        }
                        return _AlbumTrackRow(
                          song: owned,
                          queue: songs,
                          index: t.position,
                          isCurrent: owned.id == current?.id,
                        );
                      },
                    ),
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          // Quiet totals: lossless count only when it
                          // adds information the meta row lacks.
                          if (losslessCount > 0 && losslessCount < songs.length)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                '$losslessCount of ${songs.length} lossless',
                                style: const TextStyle(
                                  color: inkDim,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          if (losslessCount == songs.length && songs.isNotEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text(
                                'All lossless',
                                style: TextStyle(color: inkDim, fontSize: 13),
                              ),
                            ),
                          const SizedBox(height: 140),
                        ],
                      ),
                    ),
                  ],
                ),
                const NowPlayingDock(),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openAlbumMenu(
    WidgetRef ref,
    BuildContext context,
    Future<void> Function(bool shuffleFirst) play,
  ) async {
    final value = await showTrackMenu(
      context: context,
      groups: [
        [
          const MenuAction(
            icon: CupertinoIcons.play_fill,
            label: 'Play',
            value: 'play',
          ),
          const MenuAction(
            icon: CupertinoIcons.shuffle_medium,
            label: 'Shuffle',
            value: 'shuffle',
          ),
        ],
        [
          const MenuAction(
            icon: CupertinoIcons.square_arrow_up,
            label: 'Share',
            value: 'share',
          ),
        ],
      ],
    );
    if (!context.mounted) return;
    switch (value) {
      case 'play':
        HapticFeedback.mediumImpact();
        await play(false);
        break;
      case 'shuffle':
        HapticFeedback.selectionClick();
        await play(true);
        break;
      case 'share':
        SharePlus.instance.share(
          ShareParams(text: '${widget.album.title} - ${widget.album.artist}'),
        );
        break;
    }
  }
}

class _AlbumTrackRow extends ConsumerWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  final bool isCurrent;

  const _AlbumTrackRow({
    required this.song,
    required this.queue,
    required this.index,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final format = formatOf(song.path);
    final formatWord = format == AudioFormat.unknown ? '' : formatLabel(format);
    return CascadeIn(
      delayMs: index.clamp(1, 10) * 30,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
        onTap: () => _tapToPlay(ref, context, song, queue),
        leading: SizedBox(
          width: 30,
          child: Text(
            '$index',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isCurrent ? archPink : inkDim,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isCurrent ? archPink : ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          formatWord.isEmpty ? song.artist : '${song.artist} - $formatWord',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: inkDim, fontSize: 13),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isCurrent)
              const NowBars()
            else
              Text(
                fmtDuration(song.duration),
                style: const TextStyle(color: inkDim),
              ),
            IconButton(
              icon: const Icon(CupertinoIcons.ellipsis, color: inkDim),
              onPressed: () => showSongMenu(ref, context, song),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistList extends ConsumerWidget {
  const _ArtistList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(artistsProvider);
    final followed = ref.watch(followedProvider);
    if (artists.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Text('No artists match.', style: TextStyle(color: inkDim)),
        ),
      );
    }
    return SliverList.builder(
      itemCount: artists.length,
      itemBuilder: (context, i) {
        final entry = artists[i];
        final isFollowed = followed.contains(entry.name);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          onTap: () => ArtistPage.openIfAbsent(context, entry.name),
          leading: const CircleAvatar(
            radius: 26,
            backgroundColor: paperRaised,
            child: Icon(Icons.person, color: inkDim),
          ),
          title: Text(
            entry.name,
            maxLines: 1,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${entry.songs.length} songs',
            style: const TextStyle(color: inkDim),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFollowed)
                const Icon(Icons.check_circle, color: archPink, size: 20),
              TextButton(
                onPressed: () =>
                    ref.read(followedProvider.notifier).toggle(entry.name),
                child: Text(isFollowed ? 'Following' : 'Follow'),
              ),
              const Icon(Icons.chevron_right_rounded, color: inkDim),
            ],
          ),
        );
      },
    );
  }
}
