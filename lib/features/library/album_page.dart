import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/art_tone.dart';
import '../../core/badges.dart';
import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import '../needle/download_sheet.dart' show showDownloadSheet;
import '../player/format_marks.dart';
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction, showSongMenu;
import '../shell/morph_menu.dart' show showMorphMenu;
import '../shell/dock.dart';
import 'add_to_playlist.dart' show showAddToPlaylistSheet;
import 'data/playlist_store.dart';
import 'library_providers.dart';
import 'library_search_page.dart';
import 'song_row.dart';
import 'song_select.dart';
import 'artist_hub_page.dart';

Future<void> _tapToPlay(
  WidgetRef ref,
  BuildContext context,
  Song song,
  List<Song> queue,
) async {
  final handler = ref.read(audioHandlerProvider);
  await playAndOpen(ref, context, () => handler.playSong(song, queue));
}

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

/// Album page, WA0027/28/29 grammar in our skin: slim pinned bar,
/// centered art card that upgrades embedded art to hi-res remote
/// art, voice title + pink artist + meta line, sticky controls row
/// (shuffle / pink Play / add-all), MORE blurb, numbered rows,
/// plain-text credits footer. Page wash follows the cover art.
class AlbumPage extends ConsumerStatefulWidget {
  final Album album;
  const AlbumPage({super.key, required this.album});

  @override
  ConsumerState<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends ConsumerState<AlbumPage> {
  /// Full-bleed page tint target, reported by the cover once its
  /// tone lands (embedded first, hi-res remote upgrades it).
  Color? _washTarget;

  /// Preview in flight (unowned tap): title key, one at a time.
  /// The row shows a spinner instead of answering twice.
  String? _loadingPreview;

  /// Select mode: owned ids ride the shared controller, unowned
  /// rows ride [_unownedSel] by normalized title.
  final _sel = SelectionController();
  final _unownedSel = <String>{};

  static String _uKey(String title) => 'u:${normTitle(title)}';

  bool get _armed => _sel.armed || _unownedSel.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _sel.addListener(() {
      if (!mounted) return;
      ref.read(selectionActiveProvider.notifier).state = _armed;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _sel.dispose();
    super.dispose();
  }

  void _syncSel() {
    ref.read(selectionActiveProvider.notifier).state = _armed;
    setState(() {});
  }

  void _exitSel() {
    _sel.exit();
    _unownedSel.clear();
    ref.read(selectionActiveProvider.notifier).state = false;
    if (mounted) setState(() {});
  }

  void _enterOwned(Song song) {
    if (_armed) return;
    HapticFeedback.mediumImpact();
    _sel.enter(song.id);
    _syncSel();
  }

  void _enterUnowned(String title) {
    if (_armed) return;
    HapticFeedback.mediumImpact();
    _unownedSel.add(_uKey(title));
    _syncSel();
  }

  void _toggleOwned(Song song) {
    _sel.toggle(song.id);
    if (!_armed) {
      _unownedSel.clear();
    }
    _syncSel();
  }

  void _toggleUnowned(String title) {
    final k = _uKey(title);
    if (_unownedSel.contains(k)) {
      _unownedSel.remove(k);
    } else {
      _unownedSel.add(k);
    }
    if (!_armed) _sel.exit();
    _syncSel();
  }

  Future<void> _previewUnowned(
    BuildContext context,
    WidgetRef ref,
    _DisplayTrack t,
    String cover,
  ) async {
    if (_loadingPreview != null) return;
    setState(() => _loadingPreview = t.title);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final pv = await ref
          .read(metadataServiceProvider)
          .trackPreviewFor(
            title: t.title,
            artist: widget.album.artist,
            album: widget.album.title,
          );
      if (!context.mounted) return;
      if (pv == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Preview unavailable for this track')),
        );
        return;
      }
      final handler = ref.read(audioHandlerProvider);
      await playAndOpen(
        ref,
        context,
        () => handler.playPreview(
          uri: Uri.parse(pv.preview),
          title: t.title,
          artist: widget.album.artist,
          album: widget.album.title,
          coverUrl: pv.cover.isEmpty ? null : pv.cover,
          previewId: -(100000 + t.position),
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingPreview = null);
    }
  }

  Future<void> _unownedMenu(
    BuildContext btnContext,
    WidgetRef ref,
    _DisplayTrack t,
    String cover,
  ) async {
    final value = await showMorphMenu(
      context: btnContext,
      items: [
        const MenuAction(
          icon: CupertinoIcons.play_fill,
          label: 'Preview',
          value: 'preview',
        ),
        const MenuAction(
          icon: CupertinoIcons.cloud_download,
          label: 'Pull via Needle',
          value: 'pull',
        ),
        MenuAction(
          icon: CupertinoIcons.person,
          label: 'Go to Artist',
          subtitle: widget.album.artist,
          value: 'artist',
        ),
        MenuAction(
          icon: CupertinoIcons.square_arrow_up,
          label: 'Share',
          subtitle: '${t.title} - ${widget.album.artist}',
          value: 'share',
        ),
      ],
    );
    if (!btnContext.mounted) return;
    switch (value) {
      case 'preview':
        await _previewUnowned(btnContext, ref, t, cover);
        break;
      case 'pull': {
        HapticFeedback.selectionClick();
        final ok = await showDownloadSheet(
          btnContext,
          ref,
          title: t.title,
          artist: widget.album.artist,
          album: widget.album.title,
        );
        if (ok && btnContext.mounted) {
          ScaffoldMessenger.of(btnContext).showSnackBar(
            SnackBar(content: Text('Queued "${t.title}" - watch it in Needle')),
          );
        }
        break;
      }
      case 'artist':
        ArtistHubPage.openIfAbsent(btnContext, widget.album.artist);
        break;
      case 'share':
        SharePlus.instance.share(
          ShareParams(text: '${t.title} - ${widget.album.artist}'),
        );
        break;
    }
  }

  Future<void> _tapOwned(
    BuildContext context,
    WidgetRef ref,
    Song song,
    List<Song> queue,
  ) async {
    if (_armed) {
      HapticFeedback.selectionClick();
      _toggleOwned(song);
      return;
    }
    await _tapToPlay(ref, context, song, queue);
  }

  List<Song> _orderedOwned(List<_DisplayTrack> display) =>
      [for (final t in display) if (t.song != null) t.song!];

  List<Song> _selectedOwned(List<_DisplayTrack> display) {
    final want = _sel.ids;
    return [
      for (final t in display)
        if (t.song != null && want.contains(t.song!.id)) t.song!,
    ];
  }

  List<PendingTrack> _selectedPending(
    List<_DisplayTrack> display,
    String artist,
    String album,
  ) {
    return [
      for (final t in display)
        if (t.song == null && _unownedSel.contains(_uKey(t.title)))
          PendingTrack(title: t.title, artist: artist, album: album),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final current = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    final songs = album.songs;
    ArchLog.i('nav', 'album page: ${album.title} (${songs.length} tracks)');
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

    final albumKey =
        '${album.artist.toLowerCase()}\x00${album.title.toLowerCase()}';
    final resolved = ref.watch(albumTracklistProvider(albumKey)).value ?? [];
    final facts = ref.watch(albumFactsProvider(albumKey)).value;
    final blurb = ref.watch(albumBlurbProvider(albumKey)).value;
    final hireUrl = ref.watch(
      albumHiResCoverProvider(
        '${album.artist.toLowerCase()}\x00${album.title.toLowerCase()}\x00${songs.first.title.toLowerCase()}',
      ),
    ).value;
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

    final ordered = _orderedOwned(displayTracks);
    final total = songs.fold(Duration.zero, (sum, s) => sum + s.duration);
    AudioFormat? uniform;
    {
      final first = formatOf(songs.first.path);
      final same =
          first != AudioFormat.unknown &&
          songs.every((s) => formatOf(s.path) == first);
      if (same) uniform = first;
    }
    var year = 0;
    for (final s in songs) {
      if (s.year > 0) {
        year = s.year;
        break;
      }
    }
    final dateLine = _dateLine(facts?.date ?? '', year);
    final label = (facts?.label ?? '').trim();
    final copyright = year > 0 && label.isNotEmpty
        ? '\u00a9 $year $label'
        : null;
    final isThis = current != null && songs.any((s) => s.id == current.id);
    final showPause = isThis && playing;

    Future<void> play(bool shuffleFirst) async {
      if (ordered.isEmpty) return;
      final handler = ref.read(audioHandlerProvider);
      if (shuffleFirst) {
        await playAndOpen(
          ref,
          context,
          () => handler.playShuffled(ordered),
        );
      } else {
        await playAndOpen(
          ref,
          context,
          () => handler.playSong(ordered.first, ordered),
        );
      }
    }

    Future<void> addAll() async {
      HapticFeedback.selectionClick();
      final pending = [
        for (final t in displayTracks)
          if (t.song == null)
            PendingTrack(
              title: t.title,
              artist: album.artist,
              album: album.title,
            ),
      ];
      await showAddToPlaylistSheet(ref, context, ordered, pending: pending);
    }

    final selecting = _armed;
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear = selecting
        ? 380.0
        : collapsed
        ? 120.0
        : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);

    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) _exitSel();
      },
      child: TweenAnimationBuilder<Color?>(
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
                      _AlbumBar(
                        album: album,
                        songs: songs,
                        hireUrl: hireUrl,
                        wash: page,
                        uniform: uniform,
                        releaseType: facts?.releaseType ?? '',
                        onWash: (c) {
                          if (!mounted || c == _washTarget) return;
                          setState(() => _washTarget = c);
                        },
                        onBack: () => selecting
                            ? _exitSel()
                            : Navigator.of(context).maybePop(),
                        onMore: (c) =>
                            _openAlbumMenu(ref, c, play, addAll),
                        onArtist: () => ArtistHubPage.openIfAbsent(
                          context,
                          album.artist,
                        ),
                      ),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _ControlsHeader(
                          wash: page,
                          showPause: showPause,
                          onPlayPause: () {
                            HapticFeedback.mediumImpact();
                            if (showPause) {
                              ref.read(audioHandlerProvider).pause();
                            } else {
                              play(false);
                            }
                          },
                          onShuffle: () {
                            HapticFeedback.selectionClick();
                            play(true);
                          },
                          onAdd: addAll,
                        ),
                      ),
                      if (blurb != null && blurb.isNotEmpty)
                        SliverToBoxAdapter(child: _Blurb(text: blurb)),
                      SliverList.builder(
                        itemCount: displayTracks.length,
                        itemBuilder: (context, i) {
                          final t = displayTracks[i];
                          final owned = t.song;
                          final isCurrent = owned != null &&
                              owned.id == current?.id;
                          final sel = selecting
                              ? (owned != null
                                  ? _sel.ids.contains(owned.id)
                                  : _unownedSel.contains(_uKey(t.title)))
                              : null;
                          return CascadeIn(
                            delayMs: (i + 1).clamp(1, 10) * 30,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _AlbumTrackRow(
                                  track: t,
                                  selected: sel,
                                  isCurrent: isCurrent,
                                  loadingPreview:
                                      _loadingPreview == t.title &&
                                      owned == null,
                                  onTap: owned == null
                                      ? () {
                                          if (selecting) {
                                            HapticFeedback.selectionClick();
                                            _toggleUnowned(t.title);
                                            return;
                                          }
                                          _previewUnowned(
                                            context,
                                            ref,
                                            t,
                                            hireUrl ?? '',
                                          );
                                        }
                                      : () => _tapOwned(
                                          context,
                                          ref,
                                          owned,
                                          ordered,
                                        ),
                                  onHold: owned == null
                                      ? () => _enterUnowned(t.title)
                                      : () => _enterOwned(owned),
                                  onMore: owned == null
                                      ? (btnContext) => _unownedMenu(
                                          btnContext,
                                          ref,
                                          t,
                                          hireUrl ?? '',
                                        )
                                      : null,
                                ),
                                if (i < displayTracks.length - 1)
                                  const Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: Color(0x140B0B0D),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                      SliverToBoxAdapter(
                        child: _Credits(
                          lossless: uniform != null &&
                              formatLossless(uniform),
                          dateLine: dateLine,
                          countLine:
                              '${songs.length} song${songs.length == 1 ? '' : 's'}, ${fmtDuration(total)}',
                          copyright: copyright,
                          label: label,
                          onLabel: label.isEmpty
                              ? null
                              : () {
                                  HapticFeedback.selectionClick();
                                  ref
                                          .read(libraryQueryProvider.notifier)
                                          .state = label;
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const LibrarySearchPage(),
                                    ),
                                  );
                                },
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: bottomClear),
                      ),
                    ],
                  ),
                  if (!selecting) const NowPlayingDock(),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: AnimatedSlide(
                      duration: Motion.reduced(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 350),
                      curve: Motion.arrival,
                      offset: selecting
                          ? Offset.zero
                          : const Offset(0, 2),
                      child: AnimatedOpacity(
                        duration: Motion.reduced(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 250),
                        opacity: selecting ? 1 : 0,
                        child: IgnorePointer(
                          ignoring: !selecting,
                          child: SelectionSheet(
                            controller: _sel,
                            ordered: () => _selectedOwned(displayTracks),
                            pendingOrdered: () => _selectedPending(
                              displayTracks,
                              album.artist,
                              album.title,
                            ),
                            onExit: _exitSel,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openAlbumMenu(
    WidgetRef ref,
    BuildContext context,
    Future<void> Function(bool shuffleFirst) play,
    Future<void> Function() addAll,
  ) async {
    final value = await showMorphMenu(
      context: context,
      items: [
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
        const MenuAction(
          icon: CupertinoIcons.music_note_list,
          label: 'Add all to playlist',
          value: 'add',
        ),
        const MenuAction(
          icon: CupertinoIcons.square_arrow_up,
          label: 'Share',
          value: 'share',
        ),
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
      case 'add':
        HapticFeedback.selectionClick();
        await addAll();
        break;
      case 'share':
        SharePlus.instance.share(
          ShareParams(text: '${widget.album.title} - ${widget.album.artist}'),
        );
        break;
    }
  }
}

/// Slim pinned bar + centered art card + voice title + pink artist
/// + meta line (WA0027). Collapses to the mini title; the wash is
/// shared with the page.
class _AlbumBar extends ConsumerWidget {
  final Album album;
  final List<Song> songs;
  final String? hireUrl;
  final Color wash;
  final AudioFormat? uniform;
  final String releaseType;
  final ValueChanged<Color>? onWash;
  final VoidCallback onBack;
  final void Function(BuildContext) onMore;
  final VoidCallback onArtist;

  static const _expanded = 500.0;

  const _AlbumBar({
    required this.album,
    required this.songs,
    required this.hireUrl,
    required this.wash,
    required this.uniform,
    required this.releaseType,
    this.onWash,
    required this.onBack,
    required this.onMore,
    required this.onArtist,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topPad = MediaQuery.paddingOf(context).top;
    final voice = artistVoiceOf(album.title);
    final genres = ref.watch(
      albumGenresProvider(
        '${album.artist.toLowerCase()}\x00${album.title.toLowerCase()}',
      ),
    ).value ??
        [];
    var year = 0;
    for (final s in songs) {
      if (s.year > 0) {
        year = s.year;
        break;
      }
    }
    final chips = [
      if (genres.isNotEmpty) _displayGenre(genres.first),
      if (year > 0) '$year',
      if (uniform != null && formatLossless(uniform!)) 'Lossless',
    ];
    final rt = releaseType.trim().toLowerCase();
    final showType = rt == 'single' || rt == 'ep';
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
            style: ArchGlass.capsule(radius: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () {
                    SharePlus.instance.share(
                      ShareParams(
                        text: '${album.title} - ${album.artist}',
                      ),
                    );
                  },
                  icon: const Icon(
                    CupertinoIcons.square_arrow_up,
                    color: ink,
                  ),
                ),
                Builder(
                  builder: (btnContext) => IconButton(
                    onPressed: () => onMore(btnContext),
                    icon: const Icon(
                      CupertinoIcons.ellipsis,
                      color: ink,
                    ),
                  ),
                ),
              ],
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
          return FlexibleSpaceBar(
            collapseMode: CollapseMode.pin,
            background: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: topPad + kToolbarHeight + 8,
                  child: Opacity(
                    opacity: 1 - collapse,
                    child: Column(
                      children: [
                        _HiResArt(
                          albumId: songs.first.albumId,
                          path: songs.first.path,
                          url: hireUrl,
                          onWash: onWash,
                        ),
                        const SizedBox(height: 14),
                        if (showType)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TypeBadge(label: rt.toUpperCase()),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            album.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: voice,
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: voiceSpacing(voice),
                              color: ink,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        GestureDetector(
                          onTap: onArtist,
                          child: Text(
                            album.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: archPink,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (chips.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            chips.join(' \u00b7 '),
                            style: const TextStyle(
                              color: inkDim,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: topPad + 12,
                  left: 64,
                  right: 64,
                  child: Opacity(
                    opacity: collapse,
                    child: Column(
                      children: [
                        Text(
                          album.title,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ink,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          album.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: inkDim,
                            fontSize: 12,
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

/// Genre display that follows language: providers hand back
/// all-lowercase tags ("hip hop", "r&b") and mixed-case ones
/// ("K-pop", "UK Garage"). Only the all-lowercase words get
/// title-cased; anything already carrying capitals is trusted.
String _displayGenre(String g) {
  return g.split(' ').map((w) {
    if (w.isEmpty || w != w.toLowerCase()) return w;
    return w.splitMapJoin(
      RegExp(r'[-&/]'),
      onMatch: (m) => m[0]!,
      onNonMatch: (p) =>
          p.isEmpty ? p : p[0].toUpperCase() + p.substring(1),
    );
  }).join(' ');
}

/// Cover card: embedded art instantly, hi-res remote fading in on
/// top, wash reported off the sharpest available palette.
class _HiResArt extends ConsumerStatefulWidget {
  final int albumId;
  final String path;
  final String? url;
  final ValueChanged<Color>? onWash;

  const _HiResArt({
    required this.albumId,
    required this.path,
    required this.url,
    this.onWash,
  });

  @override
  ConsumerState<_HiResArt> createState() => _HiResArtState();
}

class _HiResArtState extends ConsumerState<_HiResArt> {
  /// Remote palette wins the moment it lands. The embedded palette
  /// only fills before that. Two extra guards that the stateless
  /// version lacked: the palette future is created once per URL
  /// (a fresh future every build re-subscribes forever), and the
  /// remote report latches (embedded + remote alternating reports
  /// ping-ponged setState every frame).
  Future<ArtPalette?>? _remotePalette;
  String? _paletteUrl;
  bool _remoteLanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFuture();
  }

  @override
  void didUpdateWidget(covariant _HiResArt old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _syncFuture();
  }

  void _syncFuture() {
    final remote = widget.url ?? '';
    if (remote.isEmpty) {
      _remotePalette = null;
      _paletteUrl = null;
      _remoteLanded = false;
      return;
    }
    if (remote != _paletteUrl) {
      _paletteUrl = remote;
      _remoteLanded = false;
      _remotePalette = ArtTone.paletteOf(remote);
    }
  }

  void _report(Color wash) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onWash?.call(wash);
    });
  }

  @override
  Widget build(BuildContext context) {
    final embedded = ref.watch(albumPaletteProvider(widget.albumId)).value;
    if (embedded != null && !_remoteLanded) {
      _report(ArtTone.pageWashOf(embedded.wash));
    }
    return SizedBox(
      width: 240,
      height: 240,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FileArtImage(
                path: widget.path, albumId: widget.albumId, fill: true),
            if (_remotePalette != null)
              FutureBuilder<ArtPalette?>(
                future: _remotePalette,
                builder: (context, pal) {
                  if (pal.data == null) {
                    return const SizedBox.shrink();
                  }
                  if (!_remoteLanded) {
                    _remoteLanded = true;
                    _report(ArtTone.pageWashOf(pal.data!.wash));
                  }
                  return CachedNetworkImage(
                    imageUrl: widget.url!,
                    fit: BoxFit.cover,
                    memCacheWidth: 700,
                    fadeInDuration: Motion.reduced(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 400),
                    errorWidget: (_, _, _) =>
                        const SizedBox.shrink(),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Sticky controls row (WA0029): shuffle + pink Play + add-all,
/// pinned under the mini header while tracks scroll beneath.
class _ControlsHeader extends SliverPersistentHeaderDelegate {
  final Color wash;
  final bool showPause;
  final VoidCallback onPlayPause;
  final VoidCallback onShuffle;
  final VoidCallback onAdd;

  const _ControlsHeader({
    required this.wash,
    required this.showPause,
    required this.onPlayPause,
    required this.onShuffle,
    required this.onAdd,
  });

  @override
  double get minExtent => 84;
  @override
  double get maxExtent => 84;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: wash,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: onShuffle,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: paperRaised,
                shape: BoxShape.circle,
                border: Border.all(color: ink.withValues(alpha: 0.08)),
              ),
              child: const Icon(
                CupertinoIcons.shuffle_medium,
                color: ink,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: onPlayPause,
              child: Container(
                height: 52,
                decoration: const BoxDecoration(
                  color: archPink,
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    MorphIcon(
                      iconKey: showPause,
                      child: Icon(
                        showPause
                            ? CupertinoIcons.pause_fill
                            : CupertinoIcons.play_fill,
                        color: Colors.white,
                        size: 22,
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
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: onAdd,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: paperRaised,
                shape: BoxShape.circle,
                border: Border.all(color: ink.withValues(alpha: 0.08)),
              ),
              child: const Icon(Icons.add_rounded, color: ink, size: 24),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_ControlsHeader old) =>
      wash != old.wash || showPause != old.showPause;
}

/// Editorial blurb with MORE expander. Hidden when neither source
/// knows the record.
class _Blurb extends StatefulWidget {
  final String text;
  const _Blurb({required this.text});

  @override
  State<_Blurb> createState() => _BlurbState();
}

class _BlurbState extends State<_Blurb> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSize(
            duration: Motion.reduced(context)
                ? Duration.zero
                : Motion.stateChange,
            curve: Motion.settle,
            alignment: Alignment.topCenter,
            child: Text(
              widget.text,
              maxLines: _open ? null : 2,
              overflow: _open ? null : TextOverflow.ellipsis,
              style: const TextStyle(color: ink, fontSize: 15, height: 1.5),
            ),
          ),
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _open = !_open);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _open ? 'LESS' : 'MORE',
                style: const TextStyle(
                  color: inkDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumTrackRow extends ConsumerWidget {
  final _DisplayTrack track;
  final bool? selected;
  final bool isCurrent;
  final bool loadingPreview;
  final VoidCallback onTap;
  final VoidCallback? onHold;
  final void Function(BuildContext)? onMore;

  const _AlbumTrackRow({
    required this.track,
    required this.selected,
    required this.isCurrent,
    this.loadingPreview = false,
    required this.onTap,
    this.onHold,
    this.onMore,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = selected;
    final song = track.song;
    final dimmed = song == null;
    return ListTile(
      onTap: sel == null
          ? onTap
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      onLongPress: sel != null
          ? null
          : onHold == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onHold!();
            },
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: SizedBox(
        width: 34,
        child: sel != null
            ? CheckDot(checked: sel)
            : isCurrent
            ? const NowBars()
            : Text(
                '${track.position}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: inkDim,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isCurrent
                    ? archPink
                    : dimmed
                    ? ink.withValues(alpha: 0.55)
                    : ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (dimmed)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(
                CupertinoIcons.exclamationmark_triangle,
                color: inkDim,
                size: 15,
              ),
            ),
        ],
      ),
      subtitle: dimmed
          ? const Text(
              'Not on this device - tap to preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: inkDim, fontSize: 13),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (song == null && loadingPreview)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                color: archPink,
                strokeWidth: 2,
              ),
            )
          else if (sel == null && (song != null || onMore != null))
            Builder(
              builder: (btnContext) => IconButton(
                icon: const Icon(CupertinoIcons.ellipsis, color: inkDim),
                onPressed: () {
                  if (song != null) {
                    showSongMenu(ref, btnContext, song);
                  } else {
                    onMore?.call(btnContext);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Plain-text credits footer (WA0028): quality mark, date, counts,
/// copyright, record-label row. Only proven lines render.
class _Credits extends StatelessWidget {
  final bool lossless;
  final String dateLine;
  final String countLine;
  final String? copyright;
  final String label;
  final VoidCallback? onLabel;

  const _Credits({
    required this.lossless,
    required this.dateLine,
    required this.countLine,
    required this.copyright,
    required this.label,
    required this.onLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (lossless) ...[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/logos/arch_core_audio.png',
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              const Text(
                'Arch Core Audio',
                style: TextStyle(
                  color: ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (dateLine.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(dateLine, style: _dim),
          ],
          const SizedBox(height: 6),
          Text(countLine, style: _dim),
          if (copyright != null) ...[
            const SizedBox(height: 6),
            Text(copyright!, style: _dim),
          ],
          if (label.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text(
              'RECORD LABEL',
              style: TextStyle(
                color: inkDim,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: onLabel,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onLabel != null)
                    const Icon(
                      CupertinoIcons.chevron_right,
                      color: inkDim,
                      size: 18,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static const _dim = TextStyle(color: inkDim, fontSize: 14, height: 1.5);
}

String _dateLine(String iso, int year) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(iso.trim());
  if (m != null) {
    final months = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    final mo = int.tryParse(m.group(2)!) ?? 0;
    final day = int.tryParse(m.group(3)!) ?? 0;
    if (mo >= 1 && mo <= 12 && day >= 1) {
      return '$day ${months[mo]} ${m.group(1)}';
    }
    return '${m.group(1)}';
  }
  if (year > 0) return '$year';
  return '';
}
