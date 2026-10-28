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
import '../../core/skeleton.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import '../needle/download_sheet.dart' show showDownloadSheet;
import '../needle/needle_store.dart';
import '../needle/queue_runner.dart';
import '../needle/queue_store.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart'
    show MenuAction, showSongMenu, showTrackMenu;
import 'library_providers.dart';
import 'data/library_repository.dart';
import 'song_select.dart';
import 'album_page.dart' show AlbumPage;
import 'release_gallery.dart';
import 'remote_album_page.dart';
import 'song_row.dart';
import '../shell/dock.dart';

/// Artist page: SpotiFLAC anatomy in our skin - full-bleed hero melting
/// into a full-bleed artist wash (Apple Music-style, no white page under
/// a colorful photo), centered wordmark (true fanart.tv ClearLogo when
/// the world has one, else the name in its assigned display voice and
/// photo vibrant) with the action row on the photo, featured
/// latest-release card, Popular top 5 + expander, fan decks for the long
/// tail, About block.
/// Every block renders the moment it lands; no match = clean local page.
class ArtistPage extends ConsumerStatefulWidget {
  final String artistName;
  const ArtistPage({super.key, required this.artistName});

  /// Artists currently on the navigation stack. Pushing the same artist
  /// twice stacked identical routes - guard it.
  static final Set<String> _open = {};

  static bool openIfAbsent(BuildContext context, String artistName) {
    if (_open.contains(artistName)) return false;
    ArchLog.i('nav', 'artist open: $artistName');
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ArtistPage(artistName: artistName)),
    );
    return true;
  }

  @override
  ConsumerState<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistPage>
    with WidgetsBindingObserver {
  /// Currently bloomed fan hub, if any.
  String? _openHub;

  /// Select mode: owned top tracks only. Unowned rows preview or
  /// pull instead of joining the selection.
  final _sel = SelectionController();

  /// Full-bleed page tint target, reported by the hero once the artist
  /// tone lands. Plain nullable field on purpose: no `late`, no ticker,
  /// so a hot reload across edits can never strand the state
  /// uninitialized. The ease itself lives in a TweenAnimationBuilder.
  Color? _washTarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ArtistPage._open.add(widget.artistName);
    _sel.addListener(() {
      if (!mounted) return;
      ref.read(selectionActiveProvider.notifier).state = _sel.armed;
      setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sel.dispose();
    ArtistPage._open.remove(widget.artistName);
    super.dispose();
  }

  /// Pull-to-refresh: drop every cached lane and wait for the two the
  /// page is built around. Offline-then-online used to leave the page
  /// frozen on a stale error forever (a FutureProvider keeps its error
  /// until invalidated).
  Future<void> _refresh() async {
    final name = widget.artistName;
    ref.invalidate(artistPicProvider(name));
    ref.invalidate(artistLogoProvider(name));
    ref.invalidate(artistBioProvider(name));
    ref.invalidate(artistListenersProvider(name));
    ref.invalidate(artistTopProvider(name));
    ref.invalidate(artistReleasesProvider(name));
    ArchLog.i('meta', 'artist refresh: $name');
    try {
      await ref.read(artistTopProvider(name).future);
    } catch (_) {}
    try {
      await ref.read(artistReleasesProvider(name).future);
    } catch (_) {}
  }

  /// Back from another app: if a lane is sitting on an error, the phone
  /// probably just regained a connection — retry only the broken ones,
  /// never the whole page, so a resume costs nothing when all is well.
  void _retryFailed() {
    final name = widget.artistName;
    var retried = false;
    if (ref.read(artistPicProvider(name)).hasError) {
      ref.invalidate(artistPicProvider(name));
      retried = true;
    }
    if (ref.read(artistLogoProvider(name)).hasError) {
      ref.invalidate(artistLogoProvider(name));
      retried = true;
    }
    if (ref.read(artistBioProvider(name)).hasError) {
      ref.invalidate(artistBioProvider(name));
      retried = true;
    }
    if (ref.read(artistListenersProvider(name)).hasError) {
      ref.invalidate(artistListenersProvider(name));
      retried = true;
    }
    if (ref.read(artistTopProvider(name)).hasError) {
      ref.invalidate(artistTopProvider(name));
      retried = true;
    }
    if (ref.read(artistReleasesProvider(name)).hasError) {
      ref.invalidate(artistReleasesProvider(name));
      retried = true;
    }
    if (retried) {
      ArchLog.i('meta', 'artist retry after resume: $name');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _retryFailed();
  }

  void _exitSel() {
    _sel.exit();
    ref.read(selectionActiveProvider.notifier).state = false;
    if (mounted) setState(() {});
  }

  List<Song> _selectedOwned(List<TopTrack> tracks, List<Song> local) {
    final want = _sel.ids;
    final out = <Song>[];
    for (final t in tracks) {
      final s = ownedTopTrack(local, t.title);
      if (s != null && want.contains(s.id)) out.add(s);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(songsProvider).value ?? [];
    final local = songs
        .where(
          (s) => splitArtists(s.artist)
              .any((n) => n.toLowerCase() == widget.artistName.toLowerCase()),
        )
        .toList();
    final pic = ref.watch(artistPicProvider(widget.artistName));
    final logo = ref.watch(artistLogoProvider(widget.artistName));
    final bio = ref.watch(artistBioProvider(widget.artistName));
    final top = ref.watch(artistTopProvider(widget.artistName));
    final releases = ref.watch(artistReleasesProvider(widget.artistName));
    final followed = ref.watch(followedProvider);
    final audience = ref.watch(
      artistListenersProvider(widget.artistName),
    );
    final selecting = _sel.armed;

    // Full-bleed artist wash (Apple Music-style): page, bar and melt
    // all share one tone, so the transparent status bar never sits on a
    // stark white page above a colorful photo. Eased, never snapped.
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) _exitSel();
      },
      child: TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        begin: _washOf(context, null),
        end: _washTarget ?? _washOf(context, null),
      ),
      duration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      builder: (context, wash, _) {
        final page = wash ?? _washOf(context, null);
        // Clearance follows the docked unit so content never slides
        // under it - same rule as the library. Select mode owns the
        // bottom edge: the sheet replaces the pill.
        final collapsed = ref.watch(pillCollapsedProvider);
        final mini = ref.watch(miniVisibleProvider);
        final bottomClear = selecting
            ? 380.0
            : collapsed
            ? 120.0
            : (mini ? 200.0 : 140.0);
        return Scaffold(
          backgroundColor: page,
          body: DockScrollReporter(
            child: Stack(
              fit: StackFit.expand,
              children: [
                RefreshIndicator(
                  color: archPink,
                  onRefresh: _refresh,
                  child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    _Hero(
                      name: widget.artistName,
                      local: local,
                      top: top.value ?? const [],
                      imageUrl: pic.value,
                      logoUrl: logo.value,
                      listeners: audience.value,
                      wash: page,
                      followed: followed.contains(widget.artistName),
                      onFollow: () => _toggleFollow(
                        widget.artistName,
                        followed.contains(widget.artistName),
                      ),
                      onShare: () => SharePlus.instance.share(
                        ShareParams(text: widget.artistName),
                      ),
                      onWash: (c) {
                        if (!mounted || c == _washTarget) return;
                        setState(() => _washTarget = c);
                      },
                      onBack: () => selecting
                          ? _exitSel()
                          : Navigator.of(context).pop(),
                      onPullAll: () => _pullAllTop(
                        ref,
                        context,
                        top.value ?? const [],
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _FeaturedRelease(
                        local: local,
                        releases: releases,
                        artistName: widget.artistName,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _Popular(
                        top: top,
                        local: local,
                        artistName: widget.artistName,
                        selecting: selecting,
                        isSelected: (song) =>
                            _sel.ids.contains(song.id),
                        onToggleOwned: (song) {
                          HapticFeedback.selectionClick();
                          _sel.toggle(song.id);
                          if (!_sel.armed) _exitSel();
                        },
                        onHoldOwned: (song) {
                          if (_sel.armed) return;
                          HapticFeedback.mediumImpact();
                          _sel.enter(song.id);
                        },
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _Collaborators(
                        local: local,
                        artistName: widget.artistName,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _FanRow(
                        releases: releases,
                        local: local,
                        openHub: _openHub,
                        onHub: (label) => setState(
                          () => _openHub = _openHub == label ? null : label,
                        ),
                        artistName: widget.artistName,
                      ),
                    ),
                    SliverToBoxAdapter(child: _Bio(bio: bio)),
                    SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
                  ],
                ),
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
                          ordered: () => _selectedOwned(
                            top.value ?? const [],
                            local,
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

  Future<void> _toggleFollow(String artist, bool wasFollowed) async {
    HapticFeedback.selectionClick();
    await ref.read(followedProvider.notifier).toggle(artist);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasFollowed
              ? 'Unfollowed $artist'
              : 'Following $artist - new releases will find you',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Pull the artist's top tracks through Needle: enqueue the
  /// missing ones on the priority-first download provider.
  Future<void> _pullAllTop(
    WidgetRef ref,
    BuildContext context,
    List<TopTrack> tracks,
  ) async {
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
    HapticFeedback.mediumImpact();
    final quality = ref.read(downloadQualityProvider);
    final queue = ref.read(downloadQueueProvider.notifier);
    var n = 0;
    for (final t in tracks) {
      queue.enqueue(
        title: t.title,
        artist: widget.artistName,
        album: t.albumTitle,
        art: t.coverUrl ?? '',
        isrc: '',
        providers: downloaders,
        providerId: null,
        quality: quality,
      );
      n++;
    }
    runQueue(ProviderScope.containerOf(context, listen: false));
    ArchLog.i('artist', 'pull all top "${widget.artistName}": $n queued');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued $n — watch it in Needle')),
      );
    }
  }
}

class _Hero extends StatefulWidget {
  final String name;
  final List<Song> local;
  final List<TopTrack> top;
  final String? imageUrl;

  /// True artist wordmark (fanart.tv HD ClearLogo), when the world has
  /// one. Null = our display-font voice speaks the name instead.
  final String? logoUrl;

  /// Audience line (monthly listeners / fans / listeners) with trend.
  /// Null = nobody knows; the hero skips the line, never placeholders.
  final ArtistListeners? listeners;

  /// Page-shared wash: bar background and melt target. Reported back up
  /// via [onWash] once the artist tone resolves.
  final Color wash;
  final ValueChanged<Color>? onWash;
  final bool followed;
  final VoidCallback onFollow;
  final VoidCallback onShare;
  final VoidCallback onBack;
  final VoidCallback onPullAll;

  const _Hero({
    required this.name,
    required this.local,
    required this.top,
    required this.imageUrl,
    this.logoUrl,
    this.listeners,
    required this.wash,
    this.onWash,
    required this.followed,
    required this.onFollow,
    required this.onShare,
    required this.onBack,
    required this.onPullAll,
  });

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> {
  Future<ArtPalette?>? _palette;
  String? _reportedUrl;
  static const _expanded = 440.0;

  @override
  void initState() {
    super.initState();
    _palette = ArtTone.paletteOf(widget.imageUrl);
  }

  @override
  void didUpdateWidget(_Hero old) {
    super.didUpdateWidget(old);
    if (old.imageUrl != widget.imageUrl) {
      _palette = ArtTone.paletteOf(widget.imageUrl);
      _reportedUrl = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    final topPad = MediaQuery.paddingOf(context).top;
    return SliverAppBar(
      expandedHeight: _expanded,
      pinned: true,
      stretch: !Motion.reduced(context),
      backgroundColor: widget.wash,
      surfaceTintColor: Colors.transparent,
      // No scroll shadow: the bar and the page share one wash, and any
      // elevation hairline would read as a split at the hero bottom.
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: LiquidGlassLens(
          style: ArchGlass.circle(radius: 24, amoled: isAmoledScheme(context)),
          child: IconButton(
            onPressed: widget.onBack,
            icon: Icon(Icons.arrow_back,
                color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ),
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final collapse =
              ((_expanded - constraints.maxHeight) /
                      (_expanded - (kToolbarHeight + topPad)))
                  .clamp(0.0, 1.0);
          // White status icons over the photo, dark icons once the bar
          // has collapsed onto the light page wash.
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
                // Static photo: it used to drift down on collapse while
                // the melt stayed anchored, which tore a visible split
                // at the hero bottom mid-scroll.
                _photo(name),
                // Fixed-pixel melt pinned to the hero bottom: constant
                // softness through the collapse instead of fractional
                // stops that squeeze harsher mid-scroll. Ends in the page
                // wash, so hero and body always agree - no edge by
                // construction.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 240,
                  child: FutureBuilder<ArtPalette?>(
                    future: _palette,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.done &&
                          widget.imageUrl != null &&
                          _reportedUrl != widget.imageUrl) {
                        _reportedUrl = widget.imageUrl;
                        final toneWash = _washOf(context, snap.data?.wash);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          widget.onWash?.call(toneWash);
                        });
                      }
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.0, 0.4, 0.7, 1.0],
                            colors: [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.24),
                              widget.wash,
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Collapsed toolbar title fades in as the big name fades out.
                Positioned(
                  top: topPad + 12,
                  left: 64,
                  right: 64,
                  child: Opacity(
                    opacity: collapse,
                    child: Text(
                      name,
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
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 64,
                  child: Opacity(
                    opacity: 1 - collapse,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // True wordmark when the world has one for this
                        // artist; otherwise the name in the artist's own
                        // voice (assigned display font) and colors
                        // (photo vibrant). All centered, all on the photo.
                        if (widget.logoUrl != null)
                          CachedNetworkImage(
                            imageUrl: widget.logoUrl!,
                            height: 64,
                            fit: BoxFit.contain,
                            memCacheHeight: 160,
                            errorWidget: (_, _, _) => _voiceName(),
                          )
                        else
                          _voiceName(),
                        const SizedBox(height: 4),
                        if (widget.listeners != null)
                          _ListenersLine(
                            listeners: widget.listeners!,
                          ),
                        Text(
                          '${widget.local.length} song${widget.local.length == 1 ? '' : 's'} on device',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(
                                color: Colors.black45,
                                blurRadius: 10,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                        // Action row lives fully on the photo, above the
                        // melt: full circles on image pixels, never crossing
                        // a background seam. Big button plays owned files,
                        // or pulls the top tracks when nothing is owned.
                        const SizedBox(height: 12),
                        _ActionRow(
                          local: widget.local,
                          followed: widget.followed,
                          onFollow: widget.onFollow,
                          onShare: widget.onShare,
                          onPullAll: widget.onPullAll,
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

  /// The artist name in its assigned display voice, colored from the
  /// photo's vibrant pick. White when the vibrant sits too close to its
  /// own backdrop to read; ink when there is no photo at all (the
  /// fallback background is light). Shadows only over photos.
  Widget _voiceName() {
    final voice = artistVoiceOf(widget.name);
    return FutureBuilder<ArtPalette?>(
      future: _palette,
      builder: (context, snap) {
        final palette = snap.data;
        final hasPhoto = widget.imageUrl != null;
        final scheme = Theme.of(context).colorScheme;
        var color = Colors.white;
        if (!hasPhoto) {
          color = scheme.onSurface;
        } else if (palette != null) {
          final vibrant = palette.vibrant;
          final close =
              (vibrant.computeLuminance() - palette.photoLum).abs() < 0.25;
          if (!close) color = vibrant;
        }
        return FocalEntrance(
          child: Text(
            widget.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontFamily: voice,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: voiceSpacing(voice),
              shadows: hasPhoto
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
        );
      },
    );
  }

  Widget _photo(String name) {
    if (widget.imageUrl != null) {
      return CachedNetworkImage(
        imageUrl: widget.imageUrl!,
        fit: BoxFit.cover,
        memCacheWidth: 800,
        errorWidget: (_, _, _) => Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0.5, 0.3),
          radius: 1.1,
          colors: [const Color(0xFFFFD9DC), scheme.surfaceContainerHighest],
        ),
      ),
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name[0].toUpperCase(),
          style: const TextStyle(color: archPink, fontSize: 120),
        ),
      ),
    );
  }
}

/// Audience line under the name: "18.2M monthly listeners" with a
/// market trend arrow (green up, red down, hidden on first sight).
/// Null audience never reaches here — the hero skips the line.
class _ListenersLine extends StatelessWidget {
  final ArtistListeners listeners;
  const _ListenersLine({required this.listeners});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            formatListeners(listeners),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 15,
              shadows: [
                Shadow(
                  color: Colors.black45,
                  blurRadius: 10,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
          if (listeners.trend != 0) ...[
            const SizedBox(width: 4),
            Icon(
              listeners.trend > 0
                  ? CupertinoIcons.arrow_up_right
                  : CupertinoIcons.arrow_down_right,
              color: listeners.trend > 0
                  ? const Color(0xFF30D158)
                  : const Color(0xFFFF453A),
              size: 16,
            ),
          ],
        ],
      ),
    );
  }
}

/// Share - big play/pull - follow. The big button plays owned files
/// and pulls the top tracks when nothing is on the device.
class _ActionRow extends ConsumerWidget {
  final List<Song> local;
  final bool followed;
  final VoidCallback onFollow;
  final VoidCallback onShare;
  final VoidCallback onPullAll;

  const _ActionRow({
    required this.local,
    required this.followed,
    required this.onFollow,
    required this.onShare,
    required this.onPullAll,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pullMode = local.isEmpty;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(icon: Icons.share_rounded, onTap: onShare),
        GestureDetector(
          onTap: () async {
            HapticFeedback.mediumImpact();
            if (pullMode) {
              onPullAll();
              return;
            }
            final handler = ref.read(audioHandlerProvider);
            await playAndOpen(
              ref,
              context,
              () => handler.playSong(local.first, local),
            );
          },
          child: Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Icon(
              pullMode
                  ? CupertinoIcons.cloud_download
                  : Icons.play_arrow_rounded,
              color: ink,
              size: 32,
            ),
          ),
        ),
        _RoundButton(
          icon: followed ? Icons.star_rounded : Icons.star_outline_rounded,
          color: followed ? archPink : Colors.white,
          onTap: onFollow,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: Icon(icon, color: color, size: 26),
      ),
    );
  }
}

/// Owned match for a provider top track: normalized title only.
/// Shared by Popular rows and the select sheet so both agree on
/// what "yours" means.
Song? ownedTopTrack(List<Song> local, String title) {
  final norm = _normTopTitle(title);
  for (final s in local) {
    if (_normTopTitle(s.title) == norm) return s;
  }
  return null;
}

String _normTopTitle(String t) =>
    t.toLowerCase().replaceAll(RegExp(r'\s*\(.*?\)\s*'), '').trim();

/// Page wash: the artist's own tone pulled toward the page background,
/// contrast-clamped at 4.5:1 against page text. Dark-aware: AMOLED pulls
/// toward #000 for light text, light toward paper for ink.
Color _washOf(BuildContext context, Color? tone) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return archWashOf(tone, dark: dark, amoled: isAmoledScheme(context));
}

/// Discography hub labels shared by the featured card and the fan row.
String _hubLabel(String type) => switch (type) {
  'album' => 'Albums',
  'single' || 'ep' => 'Singles & EPs',
  'live' => 'Live',
  'compilation' => 'Compilations',
  _ => 'More',
};

/// Latest-release card floating right under the hero melt, like the
/// reference's 1989 card: newest owned album first, else the newest
/// remote release. Hides when there is nothing to feature.
class _FeaturedRelease extends ConsumerWidget {
  final List<Song> local;
  final AsyncValue<List<ReleaseGroup>> releases;
  final String artistName;

  const _FeaturedRelease({
    required this.local,
    required this.releases,
    required this.artistName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Album? owned;
    if (local.isNotEmpty) {
      final byAlbum = <String, List<Song>>{};
      for (final s in local) {
        byAlbum.putIfAbsent(s.album.toLowerCase(), () => []).add(s);
      }
      var bestYear = -1;
      var bestCount = -1;
      String? bestKey;
      for (final e in byAlbum.entries) {
        var year = 0;
        for (final s in e.value) {
          if (s.year > year) year = s.year;
        }
        if (year > bestYear ||
            (year == bestYear && e.value.length > bestCount)) {
          bestYear = year;
          bestCount = e.value.length;
          bestKey = e.key;
        }
      }
      if (bestKey != null) {
        final songs = List<Song>.from(byAlbum[bestKey]!)
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
        owned = Album(
          key: '${songs.first.artist}\u0000${songs.first.album}',
          title: songs.first.album,
          artist: songs.first.artist,
          songs: songs,
        );
      }
    }

    // Absolute latest, ordered by full release date (ISO dates
    // compare lexicographically). Dateless entries keep MB's order
    // at the back. Owned wins ONLY when strictly newer by file
    // tags — curated world dates beat local tags everywhere else.
    ReleaseGroup? remote;
    final list = releases.value;
    if (list != null && list.isNotEmpty) {
      final dated = [for (final r in list) if (r.date.trim().isNotEmpty) r]
        ..sort((a, b) => b.date.compareTo(a.date));
      final undated = [for (final r in list) if (r.date.trim().isEmpty) r];
      final ordered = [...dated, ...undated];
      remote = ordered.first;
      ArchLog.i(
        'featured',
        'candidates: ${[
          for (final r in ordered.take(5))
            '${r.title} [${r.type}/${r.date.isEmpty ? 'nodate' : r.date}]',
        ].join(' | ')} -> pick ${remote.title}',
      );
    }
    var ownedYear = 0;
    if (owned != null) {
      for (final s in owned.songs) {
        if (s.year > ownedYear) ownedYear = s.year;
      }
    }
    final remoteYear = remote == null
        ? -1
        : int.tryParse(remote.date.split('-').first) ?? remote.year ?? -1;
    final useOwned =
        owned != null && (remote == null || ownedYear > remoteYear);

    if (owned == null && remote == null) return const SizedBox.shrink();

    final String yearText;
    final String title;
    final Widget cover;

    /// SINGLE / EP badge when the featured release is one. Owned
    /// albums match their release-group by title; remote carries it.
    /// The badge tints from the cover art (same voice rule as the
    /// hero name), so it always belongs to its backdrop.
    String? badge;
    String paletteKey = 'none';
    Future<ArtPalette?> Function() paletteLoad = () async => null;
    void Function() open;
    if (useOwned) {
      final o = owned;
      yearText = ownedYear > 0 ? '$ownedYear' : '${o.songs.length} songs';
      title = o.title;
      final match = list?.where(
        (r) => normTitle(r.title) == normTitle(o.title),
      );
      final t = match == null || match.isEmpty
          ? ''
          : match.first.type.toLowerCase();
      if (t == 'single' || t == 'ep') badge = t.toUpperCase();
      final albumId = o.songs.first.albumId;
      paletteKey = 'art:$albumId';
      paletteLoad = () => ArtTone.paletteFromBytes(
            'art:$albumId',
            () => ArtCache.of(albumId, ArtBucket.large),
          );
      cover = FileArtImage(
        path: o.songs.first.path,
        albumId: o.songs.first.albumId,
        size: 64,
        radius: 12,
      );
      open = () {
        HapticFeedback.selectionClick();
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => AlbumPage(album: o)));
      };
    } else {
      final r = remote!;
      yearText = r.year != null ? '${r.year}' : _hubLabel(r.type);
      title = r.title;
      final t = r.type.toLowerCase();
      if (t == 'single' || t == 'ep') badge = t.toUpperCase();
      final artUrl = r.artUrl;
      if (artUrl != null && artUrl.isNotEmpty) {
        paletteKey = artUrl;
        paletteLoad = () => ArtTone.paletteOf(artUrl);
      }
      cover = ReleaseCover(release: r, owned: false, size: 64);
      open = () {
        HapticFeedback.selectionClick();
        RemoteAlbumPage.open(context, artistName, r.title);
      };
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: GestureDetector(
        onTap: open,
        child: _ReleasePalette(
          cacheKey: '$badge|${badge == null ? '' : paletteKey}',
          load: paletteLoad,
          builder: (context, pal) {
            final scheme = Theme.of(context).colorScheme;
            var bg = scheme.surfaceContainerHighest;
            if (pal != null) {
              bg = Color.lerp(scheme.surfaceContainerHighest, pal.vibrant, 0.10)!;
            }
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  cover,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                yearText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (badge != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: TypeBadge(label: badge),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Palette loader that fires once per artwork key, so the tinted
/// card and its badge never re-subscribe (and re-flicker) on every
/// parent rebuild. Same memo the tone system already keeps.
class _ReleasePalette extends StatefulWidget {
  final String cacheKey;
  final Future<ArtPalette?> Function() load;
  final Widget Function(BuildContext context, ArtPalette? palette) builder;

  const _ReleasePalette({
    required this.cacheKey,
    required this.load,
    required this.builder,
  });

  @override
  State<_ReleasePalette> createState() => _ReleasePaletteState();
}

class _ReleasePaletteState extends State<_ReleasePalette> {
  Future<ArtPalette?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  @override
  void didUpdateWidget(covariant _ReleasePalette old) {
    super.didUpdateWidget(old);
    if (old.cacheKey != widget.cacheKey) _future = widget.load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ArtPalette?>(
      future: _future,
      builder: (context, snap) => widget.builder(context, snap.data),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final int? count;
  const _SectionTitle(this.text, {this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Collaborators: every other name sharing these songs, as
/// portrait links. The merge killed phantom pages; this keeps the
/// people reachable — tap opens their page (remote-only when
/// needed). Faces come through the same cached artist-pic lane.
class _Collaborators extends StatelessWidget {
  final List<Song> local;
  final String artistName;

  const _Collaborators({required this.local, required this.artistName});

  @override
  Widget build(BuildContext context) {
    final self = artistName.toLowerCase();
    final others = <String, String>{};
    for (final s in local) {
      for (final n in splitArtists(s.artist)) {
        if (n.toLowerCase() == self) continue;
        others.putIfAbsent(n.toLowerCase(), () => n);
      }
    }
    if (others.isEmpty) return const SizedBox.shrink();
    final names = others.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Collaborators', count: names.length),
        SizedBox(
          height: 108,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: names.length,
            itemBuilder: (context, i) => _CollaboratorFace(name: names[i]),
          ),
        ),
      ],
    );
  }
}

class _CollaboratorFace extends ConsumerWidget {
  final String name;
  const _CollaboratorFace({required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pic = ref.watch(artistPicProvider(name)).value;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        ArtistPage.openIfAbsent(context, name);
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 76,
        margin: const EdgeInsets.only(right: 8),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.08),
                ),
              ),
              child: ClipOval(
                child: pic != null && pic.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: pic,
                        fit: BoxFit.cover,
                        memCacheWidth: 160,
                        errorWidget: (_, _, _) => Center(
                          child: Text(
                            name.isEmpty ? '?' : name[0].toUpperCase(),
                            style: const TextStyle(
                              color: archPink,
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      )
                    : Center(
                        child: Text(
                          name.isEmpty ? '?' : name[0].toUpperCase(),
                          style: const TextStyle(
                            color: archPink,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 12,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bio extends StatelessWidget {
  final AsyncValue<String?> bio;
  const _Bio({required this.bio});

  @override
  Widget build(BuildContext context) {
    final text = bio.value;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('About'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _ExpandableBio(text: text),
        ),
      ],
    );
  }
}

class _ExpandableBio extends StatefulWidget {
  final String text;
  const _ExpandableBio({required this.text});

  @override
  State<_ExpandableBio> createState() => _ExpandableBioState();
}

class _ExpandableBioState extends State<_ExpandableBio> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: Motion.stateChange,
          curve: Motion.settle,
          child: Text(
            widget.text,
            maxLines: _open ? null : 4,
            overflow: _open ? null : TextOverflow.ellipsis,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 15,
                height: 1.6),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _open = !_open),
          child: Text(
            _open ? 'Show less' : 'Read more',
            style: const TextStyle(
              color: archPink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Popular as swipeable pages (5 rows each) with ref-style dots.
/// No ranks, no expander - swipe left/right for more songs. Owned
/// rows play the file and join select mode; unowned rows preview
/// and pull. The `...` menu is the house context popover.
class _Popular extends ConsumerStatefulWidget {
  final AsyncValue<List<TopTrack>> top;
  final List<Song> local;
  final String artistName;

  /// Select mode (owned only): tap toggles, hold arms.
  final bool selecting;
  final bool Function(Song song) isSelected;
  final void Function(Song song) onToggleOwned;
  final void Function(Song song) onHoldOwned;

  const _Popular({
    required this.top,
    required this.local,
    required this.artistName,
    this.selecting = false,
    bool Function(Song song)? isSelected,
    void Function(Song song)? onToggleOwned,
    void Function(Song song)? onHoldOwned,
  })  : isSelected = isSelected ?? _neverSelected,
        onToggleOwned = onToggleOwned ?? _noopSong,
        onHoldOwned = onHoldOwned ?? _noopSong;

  static bool _neverSelected(Song _) => false;
  static void _noopSong(Song _) {}

  @override
  ConsumerState<_Popular> createState() => _PopularState();
}

class _PopularState extends ConsumerState<_Popular> {
  late final PageController _pages = PageController();
  int _page = 0;

  /// Preview resolving at most one at a time (keyed by rank+title).
  String? _loadingKey;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Song? _owned(String title) => ownedTopTrack(widget.local, title);

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    return widget.top.when(
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Popular'),
          GhostTrackRow(),
          GhostTrackRow(),
          GhostTrackRow(),
          GhostTrackRow(),
          GhostTrackRow(),
        ],
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (tracks) {
        if (tracks.isEmpty) return const SizedBox.shrink();
        final chunks = <List<TopTrack>>[];
        for (var i = 0; i < tracks.length; i += 5) {
          chunks.add(tracks.skip(i).take(5).toList());
        }
        final currentId = ref.watch(currentSongProvider).value?.id;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle('Popular', count: tracks.length),
            Builder(
              builder: (context) {
                // Page height derives from the rows, never the reverse:
                // two-line ListTiles size with text, so a tight budget
                // overflows the moment type scales or a subtitle grows
                // (reported: bottom overflowed by 4px). 84 per row is
                // the M3 two-line tile (72) plus real slack — the
                // Column stays min-size, the extra is never painted.
                final scale = MediaQuery.textScalerOf(
                  context,
                ).scale(1.0).clamp(1.0, 1.6);
                final pageH = chunks[0].length * 84.0 * scale + 8;
                return SizedBox(
                  height: pageH,
                  child: PageView.builder(
                controller: _pages,
                onPageChanged: (p) => setState(() => _page = p),
                itemCount: chunks.length,
                itemBuilder: (context, p) => Column(
                  children: [
                    for (final track in chunks[p])
                      _TopRow(
                        track: track,
                        owned: _owned(track.title),
                        selected: widget.selecting
                            ? widget.isSelected(
                                _owned(track.title) ?? _ghost,
                              )
                            : null,
                        loading: _loadingKey == _keyOf(track),
                        isCurrent:
                            currentId != null &&
                            (currentId == _owned(track.title)?.id ||
                                currentId == -(track.rank + 1)),
                        onTap: () => _tapTrack(track),
                        onHold: () => _holdTrack(track),
                        onDownload: _owned(track.title) == null &&
                                !widget.selecting
                            ? () => _pull(ref, context, track)
                            : null,
                        onOverflow: (btnContext) =>
                            _menuTrack(ref, btnContext, track),
                      ),
                  ],
                ),
              ),
            );
              },
            ),
            if (chunks.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < chunks.length; i++)
                      AnimatedContainer(
                        duration: Motion.stateChange,
                        width: i == _page ? 18 : 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: i == _page
                              ? archPink
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// Placeholder so unowned rows never fake a selection lookup.
  static final Song _ghost = Song(
    id: -1,
    uri: Uri(),
    title: '',
    artist: '',
    album: '',
    albumId: 0,
    duration: Duration.zero,
    year: 0,
    folderKey: '',
    folderLabel: '',
  );

  static String _keyOf(TopTrack t) => '${t.rank}:${t.title}';

  Future<void> _tapTrack(TopTrack track) async {
    final owned = _owned(track.title);
    if (widget.selecting) {
      if (owned != null) {
        HapticFeedback.selectionClick();
        widget.onToggleOwned(owned);
      } else {
        await _previewOnly(track);
      }
      return;
    }
    await _play(track);
  }

  void _holdTrack(TopTrack track) {
    if (widget.selecting) return;
    final owned = _owned(track.title);
    if (owned != null) {
      widget.onHoldOwned(owned);
      return;
    }
    HapticFeedback.mediumImpact();
    _menuTrack(ref, context, track);
  }

  Future<void> _play(TopTrack track) async {
    final owned = _owned(track.title);
    if (owned != null) {
      final handler = ref.read(audioHandlerProvider);
      await playAndOpen(
        ref,
        context,
        () => handler.playSong(owned, widget.local),
      );
      return;
    }
    await _previewOnly(track);
  }

  /// Unowned playback: provider preview first, track-lane resolve
  /// as fallback, honest toast when nothing plays.
  Future<void> _previewOnly(TopTrack track) async {
    if (_loadingKey != null) return;
    final key = _keyOf(track);
    setState(() => _loadingKey = key);
    try {
      var url = track.previewUrl;
      String? cover = track.coverUrl;
      if (url == null || url.isEmpty) {
        final pv = await ref
            .read(metadataServiceProvider)
            .trackPreviewFor(
              title: track.title,
              artist: widget.artistName,
              album: track.albumTitle,
            );
        url = pv?.preview;
        cover ??= pv?.cover;
      }
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Preview unavailable for this track'),
          ),
        );
        return;
      }
      final handler = ref.read(audioHandlerProvider);
      await playAndOpen(
        ref,
        context,
        () => handler.playPreview(
          uri: Uri.parse(url!),
          title: track.title,
          artist: widget.local.isEmpty
              ? widget.artistName
              : widget.local.first.artist,
          album: track.albumTitle,
          coverUrl: cover,
          previewId: -(track.rank + 1),
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingKey = null);
    }
  }

  Future<void> _menuTrack(
    WidgetRef ref,
    BuildContext btnContext,
    TopTrack track,
  ) async {
    final owned = _owned(track.title);
    if (owned != null) {
      await showSongMenu(ref, btnContext, owned);
      return;
    }
    final value = await showTrackMenu(
      context: btnContext,
      groups: [
        [
          const MenuAction(
            icon: CupertinoIcons.play_fill,
            label: 'Preview',
            value: 'preview',
          ),
          MenuAction(
            icon: CupertinoIcons.cloud_download,
            label: 'Pull via Needle',
            value: 'pull',
          ),
          MenuAction(
            icon: CupertinoIcons.music_note,
            label: track.title,
            subtitle: widget.artistName,
            value: 'none',
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
    if (!btnContext.mounted) return;
    switch (value) {
      case 'preview':
        await _previewOnly(track);
        break;
      case 'pull':
        await _pull(ref, btnContext, track);
        break;
      case 'share':
        SharePlus.instance.share(
          ShareParams(text: '${track.title} - ${widget.artistName}'),
        );
        break;
    }
  }

  /// Unowned pull, visible all the way: provider + quality picker,
  /// then a real queue job in the Needle hub (with its progress),
  /// never a silent background pull. Completion refreshes the
  /// library through the runner.
  Future<void> _pull(
    WidgetRef ref,
    BuildContext context,
    TopTrack track,
  ) async {
    HapticFeedback.selectionClick();
    final ok = await showDownloadSheet(
      context,
      ref,
      title: track.title,
      artist: widget.artistName,
      album: track.albumTitle,
      art: track.coverUrl ?? '',
    );
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued "${track.title}" - watch it in Needle')),
      );
    }
  }
}

class _TopRow extends StatelessWidget {
  final TopTrack track;
  final Song? owned;
  final bool? selected;
  final bool loading;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onHold;
  final VoidCallback? onDownload;
  final void Function(BuildContext) onOverflow;

  const _TopRow({
    required this.track,
    required this.owned,
    this.selected,
    this.loading = false,
    required this.isCurrent,
    required this.onTap,
    required this.onHold,
    this.onDownload,
    required this.onOverflow,
  });

  @override
  Widget build(BuildContext context) {
    final sel = selected;
    final hasFile = owned != null;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      onTap: sel == null
          ? onTap
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      onLongPress: sel != null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onHold();
            },
      leading: SizedBox(
        width: 52,
        height: 52,
        child: sel != null
            ? CheckDot(checked: sel)
            : ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: track.coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: track.coverUrl!,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        memCacheWidth: 150,
                        errorWidget: (_, _, _) => Container(
                          width: 52,
                          height: 52,
                          color: scheme.surfaceContainerHighest,
                          child: Icon(Icons.music_note,
                              color: scheme.onSurfaceVariant),
                        ),
                      )
                    : Container(
                        width: 52,
                        height: 52,
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.music_note,
                            color: scheme.onSurfaceVariant),
                      ),
              ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        style: TextStyle(
          color: isCurrent ? archPink : scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Row(
        children: [
          if (!hasFile)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: archPink.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'PREVIEW',
                style: TextStyle(
                  color: archPink,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          Expanded(
            child: Text(
              track.albumTitle,
              maxLines: 1,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasFile)
            const Padding(
              padding: EdgeInsets.only(right: 2),
              child: Icon(
                CupertinoIcons.checkmark,
                color: archPink,
                size: 16,
              ),
            ),
          if (isCurrent)
            const NowBars()
          else if (loading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                color: archPink,
                strokeWidth: 2,
              ),
            )
          else if (track.duration.inSeconds > 0)
            Text(
              fmtDuration(track.duration),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          if (onDownload != null && sel == null)
            IconButton(
              icon: Icon(
                CupertinoIcons.cloud_download,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: onDownload,
            ),
          if (sel == null)
            Builder(
              builder: (btnContext) => IconButton(
                icon: Icon(Icons.more_horiz_rounded,
                    color: scheme.onSurfaceVariant),
                onPressed: () => onOverflow(btnContext),
              ),
            ),
        ],
      ),
    );
  }
}


/// Discography as fanned cover stacks. The hubs ARE the covers:
/// latest release front and center, tap to bloom the fan, tap a cover
/// for the gallery, tap front again to collapse.
class _FanRow extends StatelessWidget {
  final AsyncValue<List<ReleaseGroup>> releases;
  final List<Song> local;
  final String? openHub;
  final ValueChanged<String> onHub;
  final String artistName;

  const _FanRow({
    required this.releases,
    required this.local,
    required this.openHub,
    required this.onHub,
    required this.artistName,
  });

  @override
  Widget build(BuildContext context) {
    return releases.when(
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Discography'),
          SizedBox(
            height: 215,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: NeverScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  GhostFanCard(),
                  GhostFanCard(),
                  GhostFanCard(),
                ],
              ),
            ),
          ),
        ],
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final groups = <String, List<ReleaseGroup>>{};
        for (final r in list) {
          groups.putIfAbsent(_hubLabel(r.type), () => []).add(r);
        }
        final ownedTitles = local.map((s) => normTitle(s.album)).toSet();
        final total = groups.values.fold<int>(0, (n, g) => n + g.length);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle('Discography', count: total),
            SizedBox(
              height: 215,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: groups.length,
                itemBuilder: (context, i) {
                  final label = groups.keys.elementAt(i);
                  return _FanStack(
                    label: label,
                    items: groups[label]!,
                    ownedTitles: ownedTitles,
                    open: openHub == label,
                    onToggle: () => onHub(label),
                    artistName: artistName,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FanStack extends StatefulWidget {
  final String label;
  final List<ReleaseGroup> items;
  final Set<String> ownedTitles;
  final bool open;
  final VoidCallback onToggle;
  final String artistName;

  const _FanStack({
    required this.label,
    required this.items,
    required this.ownedTitles,
    required this.open,
    required this.onToggle,
    required this.artistName,
  });

  @override
  State<_FanStack> createState() => _FanStackState();
}


/// Release cover with a black type badge for singles and EPs.
/// Albums stay clean; the badge only appears where kinds mix.
class _BadgedCover extends StatelessWidget {
  final ReleaseGroup release;
  final bool owned;
  final double size;

  const _BadgedCover({
    required this.release,
    required this.owned,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final t = release.type.toLowerCase();
    final isSingle = t == 'single' || t == 'ep';
    final mark = isSingle ? t.toUpperCase() : null;
    final cover = ReleaseCover(
      release: release,
      owned: owned,
      size: size,
    );
    if (mark == null) return cover;
    return Stack(
      children: [
        cover,
        Positioned(
          top: 6,
          left: 6,
          child: TypeBadge(label: mark),
        ),
      ],
    );
  }
}

class _FanStackState extends State<_FanStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    if (widget.open) _c.value = 1;
  }

  @override
  void didUpdateWidget(_FanStack old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      if (widget.open) {
        _c.animateTo(
          1,
          curve: Curves.easeOutBack,
          duration: const Duration(milliseconds: 450),
        );
      } else {
        _c.animateTo(
          0,
          curve: Motion.settle,
          duration: const Duration(milliseconds: 220),
        );
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool _owned(ReleaseGroup r) =>
      widget.ownedTitles.contains(normTitle(r.title));

  void _gallery(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReleaseGallery(
          artistName: widget.artistName,
          label: widget.label,
          items: widget.items,
          ownedTitles: widget.ownedTitles,
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    // Up to 5 covers in the fan; the count badge covers the rest.
    final shown = widget.items.take(5).toList();
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Motion.reduced(context)
            ? (widget.open ? 1.0 : 0.0)
            : _c.value;
        return Container(
          width: 195,
          margin: const EdgeInsets.only(right: 20),
          child: Column(
            children: [
              SizedBox(
                height: 150,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    for (var i = shown.length - 1; i >= 1; i--)
                      Transform.translate(
                        offset: Offset(
                          (i.isEven ? -1 : 1) * i * 13.0 * t,
                          -i * 3.0 * t,
                        ),
                        child: Transform.rotate(
                          angle: (i.isEven ? -1 : 1) * i * 0.14 * t,
                          child: GestureDetector(
                            onTap: () => _gallery(context),
                            child: _BadgedCover(
                              release: shown[i],
                              owned: _owned(shown[i]),
                              size: 118,
                            ),
                          ),
                        ),
                      ),
                    GestureDetector(
                      onTap: widget.open
                          ? () => _gallery(context)
                          : widget.onToggle,
                      child: _BadgedCover(
                        release: shown.first,
                        owned: _owned(shown.first),
                        size: 118 + 10 * t,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: widget.onToggle,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: widget.open
                              ? archPink
                              : Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${widget.items.length}',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
