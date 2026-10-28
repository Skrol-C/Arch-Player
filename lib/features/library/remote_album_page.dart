import 'package:cached_network_image/cached_network_image.dart';
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
import '../../core/skeleton.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import '../metadata/metadata_service.dart' show DzAlbumDetail, DzAlbumTrack;
import '../needle/download_sheet.dart' show showDownloadSheet;
import '../needle/needle_store.dart';
import '../needle/queue_runner.dart';
import '../needle/queue_store.dart';
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction, showTrackMenu;
import '../shell/dock.dart';
import 'artist_page.dart' show ArtistPage;
import 'library_providers.dart';
import 'library_search_page.dart';
import 'song_row.dart' show fmtDuration;

/// A provider album opened from discography hubs and the featured
/// card: the actual place, not a dead grid. Deezer-backed
/// (keyless), Arch-skinned: paper canvas, ink type, pink actions,
/// glass only on floating controls. Owned tracks play the file;
/// everything else previews; per-track and pull-all Needle pulls
/// ride the visible download queue.
class RemoteAlbumPage extends ConsumerStatefulWidget {
  final String artistName;
  final String albumTitle;

  const RemoteAlbumPage({
    super.key,
    required this.artistName,
    required this.albumTitle,
  });

  static void open(BuildContext context, String artist, String album) {
    ArchLog.i('nav', 'remote album open: $artist - $album');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RemoteAlbumPage(artistName: artist, albumTitle: album),
      ),
    );
  }

  @override
  ConsumerState<RemoteAlbumPage> createState() => _RemoteAlbumPageState();
}

class _RemoteAlbumPageState extends ConsumerState<RemoteAlbumPage> {
  Color? _washTarget;
  String? _loadingKey;

  /// Album detail is a two-request network call with no cache. Building
  /// it inline in `build()` restarted it on EVERY rebuild (wash ticks,
  /// skeleton pulse, dock providers), so the page flapped
  /// skeleton -> error -> skeleton until a response happened to win a
  /// race. One future per (artist, album) instead.
  Future<DzAlbumDetail?>? _detailFuture;

  @override
  void initState() {
    super.initState();
    _detailFuture = _loadDetail();
  }

  @override
  void didUpdateWidget(covariant RemoteAlbumPage old) {
    super.didUpdateWidget(old);
    if (old.artistName != widget.artistName ||
        old.albumTitle != widget.albumTitle) {
      _detailFuture = _loadDetail();
    }
  }

  Future<DzAlbumDetail?> _loadDetail() => ref
      .read(metadataServiceProvider)
      .dzAlbumDetailFor(
        artist: widget.artistName,
        album: widget.albumTitle,
      );

  Future<void> _preview(BuildContext context, WidgetRef ref, String title,
      String url, String cover, int rank) async {
    if (_loadingKey != null || !mounted) return;
    setState(() => _loadingKey = title);
    try {
      if (url.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Preview unavailable for this track')),
          );
        }
        return;
      }
      final handler = ref.read(audioHandlerProvider);
      await playAndOpen(
        ref,
        context,
        () => handler.playPreview(
          uri: Uri.parse(url),
          title: title,
          artist: widget.artistName,
          album: widget.albumTitle,
          coverUrl: cover.isEmpty ? null : cover,
          previewId: -(100000 + rank),
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingKey = null);
    }
  }

  Future<void> _pullAll(BuildContext context, WidgetRef ref,
      List<DzAlbumTrack> tracks, String cover) async {
    final songs = ref.read(songsProvider).value ?? [];
    final missing = [
      for (final t in tracks)
        if (_ownedMatch(songs, t.title) == null) t,
    ];
    if (missing.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Everything here is already yours.')),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    final downloaders = [
      for (final p in ref.read(installedExtensionsProvider))
        if (p.enabled && p.roles.contains('download')) p,
    ];
    if (downloaders.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No download providers enabled')),
        );
      }
      return;
    }
    final quality = ref.read(downloadQualityProvider);
    final queue = ref.read(downloadQueueProvider.notifier);
    for (final t in missing) {
      queue.enqueue(
        title: t.title,
        artist: t.artist.isEmpty ? widget.artistName : t.artist,
        album: widget.albumTitle,
        art: cover,
        isrc: t.isrc,
        providers: downloaders,
        quality: quality,
      );
    }
    runQueue(ProviderScope.containerOf(context, listen: false));
    ArchLog.i('needle', 'remote pull all "${widget.albumTitle}": ${missing.length} queued');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued ${missing.length} - watch it in Needle')),
      );
    }
  }

  static Song? _ownedMatch(List<Song> songs, String title) {
    final nt = normTitle(title);
    for (final s in songs) {
      if (normTitle(s.title) == nt) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(songsProvider).value ?? [];
    final collapsed = ref.watch(pillCollapsedProvider);
    final mini = ref.watch(miniVisibleProvider);
    final bottomClear = collapsed ? 120.0 : (mini ? 200.0 : 140.0);
    return TweenAnimationBuilder<Color?>(
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
                FutureBuilder(
                  future: _detailFuture,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const _RemoteLoading();
                    }
                    if (snap.hasError || snap.data == null) {
                      return _RemoteError(
                        name: widget.albumTitle,
                        onRetry: () =>
                            setState(() => _detailFuture = _loadDetail()),
                        onBack: () => Navigator.of(context).maybePop(),
                      );
                    }
                    final d = snap.data!;
                    if (d.tracks.isEmpty) {
                      return _RemoteError(
                        name: widget.albumTitle,
                        detail: 'No playable tracks found.',
                        onRetry: () =>
                            setState(() => _detailFuture = _loadDetail()),
                        onBack: () => Navigator.of(context).maybePop(),
                      );
                    }
                    return _RemoteBody(
                      detail: d,
                      artistName: widget.artistName,
                      wash: page,
                      bottomClear: bottomClear,
                      onWash: (c) {
                        if (!mounted || c == _washTarget) return;
                        setState(() => _washTarget = c);
                      },
                      onBack: () => Navigator.of(context).maybePop(),
                      onPreview: (t) => _preview(
                          context, ref, t.title, t.previewUrl, d.cover, t.rank),
                      previewing: _loadingKey,
                      onPull: (t) => showDownloadSheet(
                        context,
                        ref,
                        title: t.title,
                        artist: t.artist.isEmpty
                            ? widget.artistName
                            : t.artist,
                        album: d.title,
                        art: d.cover,
                        isrc: t.isrc,
                      ),
                      onPullAll: () => _pullAll(context, ref, d.tracks, d.cover),
                      ownedOf: (title) => _ownedMatch(songs, title),
                    );
                  },
                ),
                const NowPlayingDock(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RemoteLoading extends StatelessWidget {
  const _RemoteLoading();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: const [
        SliverToBoxAdapter(child: SizedBox(height: 64)),
        SliverToBoxAdapter(
          child: Center(child: GhostBlock(width: 240, height: 240, radius: 20)),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 14)),
        SliverToBoxAdapter(
          child: Center(child: GhostBlock(width: 180, height: 24, radius: 6)),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverToBoxAdapter(
          child: Center(child: GhostBlock(width: 120, height: 14, radius: 4)),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 16)),
        SliverToBoxAdapter(
          child: Column(
            children: [
              GhostTrackRow(),
              GhostTrackRow(),
              GhostTrackRow(),
              GhostTrackRow(),
              GhostTrackRow(),
            ],
          ),
        ),
      ],
    );
  }
}

class _RemoteError extends StatelessWidget {
  final String name;
  final String? detail;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  const _RemoteError({
    required this.name,
    this.detail,
    required this.onRetry,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                CupertinoIcons.music_note_2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 48),
            const SizedBox(height: 12),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              detail ?? 'This album would not open right now.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: onBack,
                  child: Text('Go back',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style:
                      FilledButton.styleFrom(backgroundColor: archPink),
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Album grammar, remote data: slim pinned bar, centered hi-res
/// cover, voice title, pink artist, meta line, pinned Play/Pull
/// row, numbered rows with per-track pull. Wash follows the cover.
class _RemoteBody extends ConsumerWidget {
  final DzAlbumDetail detail;
  final String artistName;
  final Color wash;
  final double bottomClear;
  final ValueChanged<Color> onWash;
  final VoidCallback onBack;
  final Future<void> Function(DzAlbumTrack t) onPreview;
  final String? previewing;
  final Future<void> Function(DzAlbumTrack t) onPull;
  final VoidCallback onPullAll;
  final Song? Function(String title) ownedOf;

  const _RemoteBody({
    required this.detail,
    required this.artistName,
    required this.wash,
    required this.bottomClear,
    required this.onWash,
    required this.onBack,
    required this.onPreview,
    required this.previewing,
    required this.onPull,
    required this.onPullAll,
    required this.ownedOf,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String title = detail.title;
    final String cover = detail.cover;
    final String date = detail.date;
    final String label = detail.label;
    final List<DzAlbumTrack> tracks = detail.tracks;
    final year = RegExp(r'^(\d{4})').firstMatch(date)?.group(1) ?? '';
    final voice = artistVoiceOf(title);
    final topPad = MediaQuery.paddingOf(context).top;

    if (cover.isNotEmpty) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      final amoled = isAmoledScheme(context);
      ArtTone.paletteOf(cover).then((pal) {
        if (pal == null || !context.mounted) return;
        onWash(ArtTone.pageWashOf(pal.wash, dark: dark, amoled: amoled));
      });
    }

    Future<void> playFirst() async {
      HapticFeedback.mediumImpact();
      final t = tracks.first;
      final owned = ownedOf(t.title);
      if (owned != null) {
        final handler = ref.read(audioHandlerProvider);
        final all = ref.read(songsProvider).value ?? [];
        await playAndOpen(
            ref, context, () => handler.playSong(owned, all));
        return;
      }
      await onPreview(t);
    }

    return CustomScrollView(
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverAppBar(
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
              style: ArchGlass.circle(
                  radius: 24, amoled: isAmoledScheme(context)),
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
                style: ArchGlass.capsule(
                    radius: 24, amoled: isAmoledScheme(context)),
                child: IconButton(
                  onPressed: () {
                    SharePlus.instance.share(
                        ShareParams(text: '$title - $artistName'));
                  },
                  icon: Icon(CupertinoIcons.square_arrow_up,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            ),
          ],
          flexibleSpace: LayoutBuilder(
            builder: (context, constraints) {
              const expanded = 400.0;
              final collapse = ((expanded - constraints.maxHeight) /
                      (expanded - (kToolbarHeight + topPad)))
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
                            if (cover.isNotEmpty)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: CachedNetworkImage(
                                  imageUrl: cover,
                                  width: 220,
                                  height: 220,
                                  memCacheWidth: 700,
                                  fit: BoxFit.cover,
                                  fadeInDuration: Motion.reduced(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 400),
                                  errorWidget: (_, _, _) =>
                                      const SizedBox(
                                          width: 220, height: 220),
                                ),
                              )
                            else
                              Container(
                                width: 220,
                                height: 220,
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Icon(Icons.album_outlined,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    size: 72),
                              ),
                            const SizedBox(height: 14),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                title,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: voice,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: voiceSpacing(voice),
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            GestureDetector(
                              onTap: () => ArtistPage.openIfAbsent(
                                  context, artistName),
                              child: Text(
                                artistName,
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
                            if (year.isNotEmpty ||
                                tracks.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                [
                                  if (year.isNotEmpty) year,
                                  '${tracks.length} track${tracks.length == 1 ? '' : 's'}',
                                ].join(' \u00b7 '),
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 13),
                              ),
                            ],
                            if (label.trim().isNotEmpty) ...[
                              const SizedBox(height: 2),
                              GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  ref
                                      .read(libraryQueryProvider.notifier)
                                      .state = label.trim();
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const LibrarySearchPage(),
                                    ),
                                  );
                                },
                                child: Text(
                                  label.trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: archPink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
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
                        child: Text(
                          title,
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
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _ControlsHeader(
            wash: wash,
            onPlay: playFirst,
            onPullAll: onPullAll,
          ),
        ),
        SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (context, i) {
            final t = tracks[i];
            final owned = ownedOf(t.title);
            return CascadeIn(
              delayMs: (i + 1).clamp(1, 10) * 30,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RemoteTrackRow(
                    track: t,
                    owned: owned != null,
                    loading: previewing == t.title,
                    onTap: () {
                      if (owned != null) {
                        HapticFeedback.mediumImpact();
                        final handler = ref.read(audioHandlerProvider);
                        final all = ref.read(songsProvider).value ?? [];
                        playAndOpen(ref, context,
                            () => handler.playSong(owned, all));
                        return;
                      }
                      onPreview(t);
                    },
                    onMore: (btnContext) =>
                        _remoteTrackMenu(ref, btnContext, t, cover),
                    onPull: () => onPull(t),
                  ),
                  if (i < tracks.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.08),
                    ),
                ],
              ),
            );
          },
        ),
        SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
      ],
    );
  }

  Future<void> _remoteTrackMenu(
      WidgetRef ref, BuildContext btnContext, DzAlbumTrack t, String cover) async {
    final value = await showTrackMenu(
      context: btnContext,
      groups: [
        [
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
            subtitle: artistName,
            value: 'artist',
          ),
          MenuAction(
            icon: CupertinoIcons.square_arrow_up,
            label: 'Share',
            subtitle: '${t.title} - $artistName',
            value: 'share',
          ),
        ],
      ],
    );
    if (!btnContext.mounted) return;
    switch (value) {
      case 'preview':
        await onPreview(t);
        break;
      case 'pull':
        await onPull(t);
        break;
      case 'artist':
        ArtistPage.openIfAbsent(btnContext, artistName);
        break;
      case 'share':
        SharePlus.instance.share(
            ShareParams(text: '${t.title} - $artistName'));
        break;
    }
  }
}

class _ControlsHeader extends SliverPersistentHeaderDelegate {
  final Color wash;
  final VoidCallback onPlay;
  final VoidCallback onPullAll;

  const _ControlsHeader({
    required this.wash,
    required this.onPlay,
    required this.onPullAll,
  });

  @override
  double get minExtent => 84;
  @override
  double get maxExtent => 84;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: wash,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.mediumImpact();
                onPlay();
              },
              child: Container(
                height: 52,
                decoration: const BoxDecoration(
                  color: archPink,
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(CupertinoIcons.play_fill,
                        color: Colors.white, size: 22),
                    SizedBox(width: 4),
                    Text(
                      'Play',
                      style: TextStyle(
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
            onTap: () {
              HapticFeedback.selectionClick();
              onPullAll();
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
              child: Icon(CupertinoIcons.cloud_download,
                  color: Theme.of(context).colorScheme.onSurface, size: 24),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_ControlsHeader old) => wash != old.wash;
}

class _RemoteTrackRow extends StatelessWidget {
  final DzAlbumTrack track;
  final bool owned;
  final bool loading;
  final VoidCallback onTap;
  final void Function(BuildContext btnContext) onMore;
  final VoidCallback onPull;

  const _RemoteTrackRow({
    required this.track,
    required this.owned,
    this.loading = false,
    required this.onTap,
    required this.onMore,
    required this.onPull,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: SizedBox(
        width: 34,
        child: Text(
          '${track.rank}',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (owned)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(
                CupertinoIcons.checkmark,
                color: archPink,
                size: 15,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                CupertinoIcons.exclamationmark_triangle,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 15,
              ),
            ),
        ],
      ),
      subtitle: owned
          ? null
          : Text(
              'Not on this device - tap to preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (track.durationSecs > 0)
            Text(
              fmtDuration(Duration(seconds: track.durationSecs)),
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          if (!owned && !loading)
            IconButton(
              icon: Icon(CupertinoIcons.cloud_download,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              onPressed: onPull,
            ),
          if (loading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                color: archPink,
                strokeWidth: 2,
              ),
            ),
          Builder(
            builder: (btnContext) => IconButton(
              icon: Icon(CupertinoIcons.ellipsis,
                  color:
                      Theme.of(btnContext).colorScheme.onSurfaceVariant),
              onPressed: () => onMore(btnContext),
            ),
          ),
        ],
      ),
    );
  }
}
