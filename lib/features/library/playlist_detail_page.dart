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
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../needle/download_sheet.dart' show showDownloadSheet;
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction;
import '../shell/morph_menu.dart' show showMorphMenu;
import '../shell/dock.dart';
import 'add_to_playlist.dart' show newPlaylistDialog;
import 'data/playlist_store.dart';
import 'library_providers.dart';
import 'playlist_art.dart';
import 'playlist_cover.dart'
    show PlaylistSongPicker, changePlaylistCover, playlistCoverPalette;
import 'playlists_providers.dart';
import 'song_row.dart';
import 'song_select.dart';

/// Playlist detail (WA0077 / WA0079 grammar): full-bleed gradient
/// wash hero, glass back + glass actions, centered title / owner /
/// updated, shuffle + Play + add row, then the tracks. Favourites
/// rows carry a leading star; custom lists show plain rows.
/// Empty lists render the WA0078 state: big gradient tile + CTA.
class PlaylistDetailPage extends ConsumerStatefulWidget {
  final String playlistId;

  const PlaylistDetailPage({super.key, required this.playlistId});

  static void open(BuildContext context, {required String playlistId}) {
    ArchLog.i('nav', 'playlist open: $playlistId');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(playlistId: playlistId),
      ),
    );
  }

  @override
  ConsumerState<PlaylistDetailPage> createState() =>
      _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  Color? _washTarget;
  bool _reordering = false;
  final _sel = SelectionController();

  @override
  void initState() {
    super.initState();
    _sel.addListener(() {
      if (!mounted) return;
      ref.read(selectionActiveProvider.notifier).state = _sel.armed;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _sel.dispose();
    super.dispose();
  }

  /// Hold enters select mode; tap toggles while armed, plays when not.
  void _enterSelect(Song song) {
    if (_sel.armed) return;
    HapticFeedback.mediumImpact();
    _sel.enter(song.id);
  }

  Future<void> _tapRow(
    WidgetRef ref,
    BuildContext context,
    Song song,
    List<Song> queue,
  ) async {
    if (_sel.armed) {
      HapticFeedback.selectionClick();
      _sel.toggle(song.id);
      return;
    }
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(
      ref,
      context,
      () => handler.playSong(song, queue),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(playlistsProvider);
    Playlist? found;
    for (final p in lists) {
      if (p.id == widget.playlistId) found = p;
    }
    final songs = ref.watch(songsProvider).value ?? [];
    // Deleted elsewhere while open: explicit dead end, never blank.
    if (found == null) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(title: const Text('Playlist')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.music_note_list,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 64,
              ),
              const SizedBox(height: 12),
              const Text('This playlist is gone.'),
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
    final playlist = found;
    final members = playlistTracks(playlist, songs);
    final unmatched = playlistUnmatched(playlist, songs);
    final collapsed = ref.watch(pillCollapsedProvider);
    final selecting = _sel.armed;
    // Select mode owns the bottom edge: the docked sheet replaces
    // the pill, so clearance is the sheet — not the dock.
    final bottomClear = selecting
        ? 380.0
        : collapsed
        ? 120.0
        : 200.0;

    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) _sel.exit();
      },
      child: TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        begin: ArtTone.pageWashOf(null,
            dark: Theme.of(context).brightness == Brightness.dark,
            amoled: isAmoledScheme(context)),
        end: _washTarget ??
            ArtTone.pageWashOf(null,
                dark: Theme.of(context).brightness == Brightness.dark,
                amoled: isAmoledScheme(context)),
      ),
      duration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      builder: (context, wash, _) {
        final page = wash ??
            ArtTone.pageWashOf(null,
                dark: Theme.of(context).brightness == Brightness.dark,
                amoled: isAmoledScheme(context));
        return Scaffold(
          backgroundColor: page,
          body: DockScrollReporter(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomScrollView(
                  slivers: [
                    _Hero(
                      playlist: playlist,
                      memberCount: members.length,
                      songs: members,
                      wash: page,
                      onWash: (c) {
                        if (!mounted || c == _washTarget) return;
                        setState(() => _washTarget = c);
                      },
                      onBack: () => selecting
                          ? _sel.exit()
                          : Navigator.of(context).maybePop(),
                      onAdd: () => _openPicker(context, ref, playlist),
                      onMenu: (c) =>
                          _headerMenu(c, ref, playlist, members),
                    ),
                    SliverToBoxAdapter(
                      child: _Controls(
                        playlist: playlist,
                        members: members,
                        reordering: _reordering,
                        onReorderToggle: () => setState(
                          () => _reordering = !_reordering,
                        ),
                        onAdd: () => _openPicker(context, ref, playlist),
                      ),
                    ),
                    if (members.isEmpty && unmatched.isEmpty)
                      SliverToBoxAdapter(
                        child: _DetailEmpty(
                          isSystem: playlist.isSystem,
                          onAdd: () => _openPicker(context, ref, playlist),
                        ),
                      )
                    else ...[
                      if (members.isNotEmpty) ...[
                        if (_reordering && !selecting)
                          SliverReorderableList(
                            itemCount: members.length,
                            onReorderItem: (a, b) => ref
                                .read(playlistsProvider.notifier)
                                .reorder(playlist.id, a, b),
                            itemBuilder: (context, i) => _ReorderRow(
                              key: ValueKey(
                                '${playlist.id}:${members[i].id}',
                              ),
                              song: members[i],
                              starred: playlist.isSystem,
                              isCurrent:
                                  ref.watch(currentSongProvider).value?.id ==
                                  members[i].id,
                            ),
                          )
                        else
                          SliverList.builder(
                            itemCount: members.length,
                            itemBuilder: (context, i) {
                              final s = members[i];
                              final isCurrent =
                                  ref.watch(currentSongProvider).value?.id ==
                                  s.id;
                              return CascadeIn(
                                delayMs: (i + 1).clamp(1, 10) * 30,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _PlaylistRow(
                                      song: s,
                                      queue: members,
                                      starred: playlist.isSystem,
                                      selected: selecting
                                          ? _sel.ids.contains(s.id)
                                          : null,
                                      isCurrent: isCurrent,
                                      onRemove: selecting || playlist.isSystem
                                          ? null
                                          : () => _remove(
                                              context,
                                              ref,
                                              playlist,
                                              s,
                                            ),
                                      onSelectTap: selecting
                                          ? () =>
                                              _tapRow(ref, context, s, members)
                                          : null,
                                      onHold: selecting
                                          ? null
                                          : () => _enterSelect(s),
                                    ),
                                    if (i < members.length - 1)
                                      Divider(
                                        height: 1,
                                        thickness: 1,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.12),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                      if (unmatched.isNotEmpty && !selecting)
                        SliverList.builder(
                          itemCount: unmatched.length,
                          itemBuilder: (context, i) {
                            final r = unmatched[i];
                            return CascadeIn(
                              delayMs: (i + 1).clamp(1, 10) * 30,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _PendingRow(
                                    pending: r,
                                    onTap: () => _pullPending(
                                        context, ref, playlist, r),
                                    onRemove: () => ref
                                        .read(playlistsProvider.notifier)
                                        .removePending(playlist.id, r),
                                  ),
                                  if (i < unmatched.length - 1)
                                    Divider(
                                      height: 1,
                                      thickness: 1,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.12),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
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
                          ordered: () => members,
                          onExit: () => _sel.exit(),
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

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    Song song,
  ) async {
    HapticFeedback.selectionClick();
    await ref.read(playlistsProvider.notifier).removeSong(playlist.id, song.id);
  }

  Future<void> _headerMenu(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    List<Song> members,
  ) async {
    final value = await showMorphMenu(
      context: context,
      items: [
        const MenuAction(
          icon: CupertinoIcons.person_badge_plus,
          label: 'Add songs',
          value: 'add',
        ),
        if (!playlist.isSystem) ...[
          const MenuAction(
            icon: CupertinoIcons.photo,
            label: 'Change cover art',
            value: 'cover',
          ),
          const MenuAction(
            icon: CupertinoIcons.pencil,
            label: 'Rename',
            value: 'rename',
          ),
          MenuAction(
            icon: CupertinoIcons.arrow_up_arrow_down,
            label: _reordering ? 'Done reordering' : 'Reorder',
            value: 'reorder',
          ),
        ],
        const MenuAction(
          icon: CupertinoIcons.square_arrow_up,
          label: 'Share',
          value: 'share',
        ),
        if (!playlist.isSystem)
          const MenuAction(
            icon: CupertinoIcons.delete,
            label: 'Delete playlist',
            value: 'delete',
          ),
      ],
    );
    if (!context.mounted || value == null) return;
    final notifier = ref.read(playlistsProvider.notifier);
    switch (value) {
      case 'add':
        _openPicker(context, ref, playlist);
        break;
      case 'cover':
        if (context.mounted) {
          await changePlaylistCover(ref, context, playlist, members);
        }
        break;
      case 'rename':
        newPlaylistDialog(context, ref, existing: playlist);
        break;
      case 'reorder':
        setState(() => _reordering = !_reordering);
        break;
      case 'share':
        HapticFeedback.selectionClick();
        final names = [
          for (final s in members.take(10)) '${s.title} - ${s.artist}',
        ].join('\n');
        SharePlus.instance.share(
          ShareParams(text: '${playlist.name}\n$names'),
        );
        break;
      case 'delete':
        await notifier.delete(playlist.id);
        if (context.mounted) Navigator.of(context).maybePop();
        break;
    }
  }

  Future<void> _pullPending(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    PendingTrack pending,
  ) async {
    HapticFeedback.selectionClick();
    final ok = await showDownloadSheet(
      context,
      ref,
      title: pending.title,
      artist: pending.artist,
      album: pending.album,
    );
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Queued "${pending.title}" - watch it in Needle'),
        ),
      );
    }
  }

  void _openPicker(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
  ) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistSongPicker(playlist: playlist),
      ),
    );
  }
}

/// Gradient hero: glass back left, glass actions right, centered
/// title / `Updated X ago` / count. Gradient resolves async and the
/// page wash eases onto its midpoint.
class _Hero extends StatelessWidget {
  final Playlist playlist;
  final int memberCount;
  final List<Song> songs;
  final Color wash;
  final ValueChanged<Color>? onWash;
  final VoidCallback onBack;
  final VoidCallback onAdd;
  final void Function(BuildContext) onMenu;

  const _Hero({
    required this.playlist,
    required this.memberCount,
    required this.songs,
    required this.wash,
    this.onWash,
    required this.onBack,
    required this.onAdd,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    return SliverAppBar(
      expandedHeight: 400,
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
          style:
              ArchGlass.circle(radius: 24, amoled: isAmoledScheme(context)),
          child: IconButton(
            onPressed: onBack,
            icon: Icon(Icons.arrow_back,
                color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: LiquidGlassLens(
            style:
                ArchGlass.capsule(radius: 24, amoled: isAmoledScheme(context)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: onAdd,
                  icon: Icon(Icons.add_rounded,
                      color: Theme.of(context).colorScheme.onSurface),
                  tooltip: 'Add songs',
                ),
                Builder(
                  builder: (btnContext) => IconButton(
                    onPressed: () => onMenu(btnContext),
                    icon: Icon(
                      CupertinoIcons.ellipsis,
                      color:
                          Theme.of(btnContext).colorScheme.onSurface,
                    ),
                    tooltip: 'More',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          const expanded = 400.0;
          final collapse =
              ((expanded - constraints.maxHeight) /
                      (expanded - (kToolbarHeight + topPad)))
                  .clamp(0.0, 1.0);
          return FlexibleSpaceBar(
            collapseMode: CollapseMode.pin,
            background: Stack(
              fit: StackFit.expand,
              children: [
                _GradientWash(
                  playlist: playlist,
                  songs: songs,
                  onWash: onWash,
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 40,
                  child: Opacity(
                    opacity: 1 - collapse,
                    child: Column(
                      children: [
                        FocalEntrance(
                          child: playlist.hasCustomArt && !playlist.isSystem
                              ? FutureBuilder<ArtPalette?>(
                                  future: playlistCoverPalette(
                                    playlist.customArt,
                                  ),
                                  builder: (context, pal) {
                                    final color =
                                        PlaylistArt.coverVoiceColor(
                                          pal.data,
                                        );
                                    final voice = artistVoiceOf(
                                      playlist.name,
                                    );
                                    return Text(
                                      playlist.name,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: color,
                                        fontFamily: voice,
                                        fontSize: 32,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: voiceSpacing(voice),
                                        shadows: const [
                                          Shadow(
                                            color: Colors.black45,
                                            blurRadius: 12,
                                            offset: Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        playlist.name,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface,
                                          fontSize: 30,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                    ),
                                    if (playlist.isSystem)
                                      const Padding(
                                        padding: EdgeInsets.only(left: 6),
                                        child: Icon(
                                          Icons.star_rounded,
                                          color: archPink,
                                          size: 26,
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          updatedAgo(playlist.updatedMs),
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '$memberCount song${memberCount == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
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
                    child: Text(
                      playlist.name,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
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

class _GradientWash extends StatelessWidget {
  final Playlist playlist;
  final List<Song> songs;
  final ValueChanged<Color>? onWash;

  const _GradientWash({
    required this.playlist,
    required this.songs,
    this.onWash,
  });

  @override
  Widget build(BuildContext context) {
    // Favourites hero: the red star, page-toned per WA0077.
    if (playlist.isSystem) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: const Center(
          child: Padding(
            padding: EdgeInsets.only(bottom: 90),
            child: Icon(Icons.star_rounded, color: archPink, size: 190),
          ),
        ),
      );
    }
    // Custom cover: photo full-bleed, wash off its own palette.
    if (playlist.hasCustomArt) {
      return FutureBuilder<Uint8List?>(
        future: PlaylistArt.coverBytes(playlist.customArt),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) {
            return _AutoGradient(songs: songs, onWash: onWash);
          }
          return FutureBuilder<ArtPalette?>(
            future: playlistCoverPalette(playlist.customArt),
            builder: (context, pal) {
              final wash = ArtTone.pageWashOf(pal.data?.wash,
                  dark: Theme.of(context).brightness == Brightness.dark,
                  amoled: isAmoledScheme(context));
              WidgetsBinding.instance.addPostFrameCallback((_) {
                onWash?.call(wash);
              });
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(bytes, fit: BoxFit.cover),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.12),
                          Colors.transparent,
                          Colors.transparent,
                          wash,
                        ],
                        stops: const [0.0, 0.3, 0.6, 1.0],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    }
    return _AutoGradient(songs: songs, onWash: onWash);
  }
}

class _AutoGradient extends StatelessWidget {
  final List<Song> songs;
  final ValueChanged<Color>? onWash;

  const _AutoGradient({required this.songs, this.onWash});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Color>>(
      future: PlaylistArt.gradientFor(songs),
      builder: (context, snap) {
        final stops =
            snap.data ??
            const [Color(0xFFF6F6F8), Color(0xFFE8E8ED)];
        final wash = PlaylistArt.washFor(stops,
            dark: Theme.of(context).brightness == Brightness.dark,
            amoled: isAmoledScheme(context));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onWash?.call(wash);
        });
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [...stops, wash],
            ),
          ),
        );
      },
    );
  }
}

class _Controls extends ConsumerWidget {
  final Playlist playlist;
  final List<Song> members;
  final bool reordering;
  final VoidCallback onReorderToggle;
  final VoidCallback onAdd;

  const _Controls({
    required this.playlist,
    required this.members,
    required this.reordering,
    required this.onReorderToggle,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> play(bool shuffleFirst) async {
      if (members.isEmpty) return;
      final handler = ref.read(audioHandlerProvider);
      HapticFeedback.mediumImpact();
      if (shuffleFirst) {
        await playAndOpen(
          ref,
          context,
          () => handler.playShuffled(members),
        );
      } else {
        await playAndOpen(
          ref,
          context,
          () => handler.playSong(members.first, members),
        );
      }
    }

    final current = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    final isThis =
        current != null && members.any((s) => s.id == current.id);
    final showPause = isThis && playing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              play(true);
            },
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.08)),
              ),
              child: Icon(
                CupertinoIcons.shuffle_medium,
                color: Theme.of(context).colorScheme.onSurface,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
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
                borderRadius: BorderRadius.all(Radius.circular(28)),
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
              onAdd();
            },
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.08)),
              ),
              child: Icon(Icons.add_rounded,
                  color: Theme.of(context).colorScheme.onSurface, size: 24),
            ),
          ),
        ],
      ),
    );
  }
}

/// WA0078 state: big gradient tile + honest line + add CTA.
class _DetailEmpty extends StatelessWidget {
  final bool isSystem;
  final VoidCallback onAdd;

  const _DetailEmpty({required this.isSystem, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 24, 48, 0),
      child: Column(
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: isSystem
                  ? null
                  : const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        PlaylistArt.fallbackTop,
                        PlaylistArt.fallbackBottom,
                      ],
                    ),
              color: isSystem
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : null,
            ),
            child: isSystem
                ? const Icon(Icons.star_rounded, color: archPink, size: 96)
                : const Padding(
                    padding: EdgeInsets.all(16),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        '',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          Text(
            isSystem
                ? 'Star anything to keep it here'
                : 'Nothing here yet',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Use Add to bring songs in.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: archPink),
            onPressed: onAdd,
            child: const Text('Add songs'),
          ),
        ],
      ),
    );
  }
}

class _PlaylistRow extends ConsumerWidget {
  final Song song;
  final List<Song> queue;
  final bool starred;
  final bool isCurrent;
  final VoidCallback? onRemove;

  /// Select mode: non-null shows a leading check instead of art.
  /// [onSelectTap] toggles, [onHold] arms the mode. Trailing actions
  /// hide while selecting.
  final bool? selected;
  final VoidCallback? onSelectTap;
  final VoidCallback? onHold;

  const _PlaylistRow({
    required this.song,
    required this.queue,
    required this.starred,
    required this.isCurrent,
    this.onRemove,
    this.selected,
    this.onSelectTap,
    this.onHold,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> tap() async {
      final handler = ref.read(audioHandlerProvider);
      await playAndOpen(
        ref,
        context,
        () => handler.playSong(song, queue),
      );
    }

    final sel = selected;
    return ListTile(
      onTap: sel == null
          ? tap
          : () {
              HapticFeedback.selectionClick();
              onSelectTap?.call();
            },
      onLongPress: sel != null
          ? null
          : onHold == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onHold!();
            },
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: sel == null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (starred)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.star_rounded,
                      color: archPink,
                      size: 18,
                    ),
                  ),
                FileArtImage(path: song.path, albumId: song.albumId),
              ],
            )
          : SizedBox(
              width: 52,
              height: 52,
              child: CheckDot(checked: sel),
            ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isCurrent
              ? archPink
              : Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent)
            NowBars(song: song)
          else
            Text(
              fmtDuration(song.duration),
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          if (sel == null) ...[
            if (onRemove != null)
              IconButton(
                icon: Icon(
                  CupertinoIcons.minus_circle,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                onPressed: onRemove,
              )
            else
              Builder(
                builder: (btnContext) => IconButton(
                  icon: Icon(
                    CupertinoIcons.ellipsis,
                    color:
                        Theme.of(btnContext).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () => _rowMenu(ref, btnContext),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _rowMenu(WidgetRef ref, BuildContext context) async {
    final starred = ref.read(playlistsProvider.notifier).isStarred(song.id);
    final value = await showMorphMenu(
      context: context,
      items: [
        MenuAction(
          icon: starred ? CupertinoIcons.star_fill : CupertinoIcons.star,
          label: starred ? 'Unstar' : 'Star',
          value: 'star',
          selected: starred,
        ),
        const MenuAction(
          icon: CupertinoIcons.minus_circle,
          label: 'Remove from Favourites',
          value: 'remove',
        ),
      ],
    );
    if (!context.mounted || value == null) return;
    final notifier = ref.read(playlistsProvider.notifier);
    if (value == 'star') {
      await notifier.toggleStar(song.id);
    } else if (value == 'remove') {
      await notifier.removeSong(Playlist.favouritesId, song.id);
    }
  }
}

/// Greyed unowned entry with a warning triangle. Tap offers the
/// Needle pull; the row auto-upgrades to a real track when the file
/// lands in a scan.
class _PendingRow extends StatelessWidget {
  final PendingTrack pending;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _PendingRow({
    required this.pending,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          CupertinoIcons.exclamationmark_triangle,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 22,
        ),
      ),
      title: Text(
        pending.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        pending.artist.isEmpty ? 'Not on this device' : pending.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'MISSING',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            icon: Icon(CupertinoIcons.minus_circle,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _ReorderRow extends StatelessWidget {
  final Song song;
  final bool starred;
  final bool isCurrent;

  const _ReorderRow({
    super.key,
    required this.song,
    required this.starred,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('inner:${song.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: 0,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(CupertinoIcons.bars,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          FileArtImage(path: song.path, albumId: song.albumId),
        ],
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
