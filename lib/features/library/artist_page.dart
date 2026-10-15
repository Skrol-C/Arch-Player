import 'package:cached_network_image/cached_network_image.dart';
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
import '../needle/needle_store.dart';
import '../needle/pull.dart';
import '../needle/sandbox.dart';
import '../needle/verify_sheet.dart';
import '../needle/session_grant.dart';
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'library_providers.dart';
import 'library_screen.dart' show AlbumPage;
import 'release_gallery.dart';
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

class _ArtistPageState extends ConsumerState<ArtistPage> {
  /// Currently bloomed fan hub, if any.
  String? _openHub;

  /// Full-bleed page tint target, reported by the hero once the artist
  /// tone lands. Plain nullable field on purpose: no `late`, no ticker,
  /// so a hot reload across edits can never strand the state
  /// uninitialized. The ease itself lives in a TweenAnimationBuilder.
  Color? _washTarget;

  @override
  void initState() {
    super.initState();
    ArtistPage._open.add(widget.artistName);
  }

  @override
  void dispose() {
    ArtistPage._open.remove(widget.artistName);
    super.dispose();
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

    // Full-bleed artist wash (Apple Music-style): page, bar and melt
    // all share one tone, so the transparent status bar never sits on a
    // stark white page above a colorful photo. Eased, never snapped.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        begin: _washOf(null),
        end: _washTarget ?? _washOf(null),
      ),
      duration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      builder: (context, wash, _) {
        final page = wash ?? _washOf(null);
        // Clearance follows the docked unit so content never slides
        // under it - same rule as the library.
        final collapsed = ref.watch(pillCollapsedProvider);
        final mini = ref.watch(miniVisibleProvider);
        final bottomClear = collapsed ? 120.0 : (mini ? 200.0 : 140.0);
        return Scaffold(
          backgroundColor: page,
          body: DockScrollReporter(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomScrollView(
                  slivers: [
                    _Hero(
                      name: widget.artistName,
                      local: local,
                      imageUrl: pic.value,
                      logoUrl: logo.value,
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
                      onBack: () => Navigator.of(context).pop(),
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
                const NowPlayingDock(),
              ],
            ),
          ),
        );
      },
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
}

class _Hero extends StatefulWidget {
  final String name;
  final List<Song> local;
  final String? imageUrl;

  /// True artist wordmark (fanart.tv HD ClearLogo), when the world has
  /// one. Null = our display-font voice speaks the name instead.
  final String? logoUrl;

  /// Page-shared wash: bar background and melt target. Reported back up
  /// via [onWash] once the artist tone resolves.
  final Color wash;
  final ValueChanged<Color>? onWash;
  final bool followed;
  final VoidCallback onFollow;
  final VoidCallback onShare;
  final VoidCallback onBack;

  const _Hero({
    required this.name,
    required this.local,
    required this.imageUrl,
    this.logoUrl,
    required this.wash,
    this.onWash,
    required this.followed,
    required this.onFollow,
    required this.onShare,
    required this.onBack,
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
          style: ArchGlass.circle(radius: 24),
          child: IconButton(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back, color: ink),
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
                        final toneWash = _washOf(snap.data?.wash);
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
                        // a background seam.
                        const SizedBox(height: 12),
                        _ActionRow(
                          local: widget.local,
                          followed: widget.followed,
                          onFollow: widget.onFollow,
                          onShare: widget.onShare,
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
        var color = Colors.white;
        if (!hasPhoto) {
          color = ink;
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
        errorWidget: (_, _, _) => Container(color: paperRaised),
      );
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.5, 0.3),
          radius: 1.1,
          colors: [Color(0xFFFFD9DC), paperRaised],
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

/// Share - big play - follow. No dead download control until Needle exists.
class _ActionRow extends ConsumerWidget {
  final List<Song> local;
  final bool followed;
  final VoidCallback onFollow;
  final VoidCallback onShare;

  const _ActionRow({
    required this.local,
    required this.followed,
    required this.onFollow,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(icon: Icons.share_rounded, onTap: onShare),
        GestureDetector(
          onTap: () async {
            if (local.isEmpty) return;
            HapticFeedback.mediumImpact();
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
            child: const Icon(Icons.play_arrow_rounded, color: ink, size: 36),
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

/// Page wash: the artist's own tone pulled most of the way to paper.
/// Light enough for ink text, tinted enough for full-bleed. Null tone =
/// the pre-load default, near-white like today.
Color _washOf(Color? tone) {
  final base = tone ?? paperRaised;
  // Uniform darker page: sit much closer to the artist's own color-
  var pull = 0.3;
  var wash = Color.lerp(base, paper, pull)!;
  // -but never darker than ink stays readable on. Walk back toward
  // paper until contrast passes 4.5:1 - deep reds go properly dark,
  // pale photos stop exactly where ink survives.
  while (pull < 1.0 && _contrast(ink, wash) < 4.5) {
    pull += 0.05;
    wash = Color.lerp(base, paper, pull)!;
  }
  return wash;
}

double _contrast(Color a, Color b) {
  final l1 = a.computeLuminance() + 0.05;
  final l2 = b.computeLuminance() + 0.05;
  return l1 > l2 ? l1 / l2 : l2 / l1;
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

    ReleaseGroup? remote;
    List<ReleaseGroup>? hubItems;
    final list = releases.value;
    if (list != null && list.isNotEmpty) {
      var pick = list.first;
      for (final r in list) {
        if (r.type == 'album') {
          pick = r;
          break;
        }
      }
      remote = pick;
      final label = _hubLabel(pick.type);
      hubItems = list.where((r) => _hubLabel(r.type) == label).toList();
    }

    if (owned == null && remote == null) return const SizedBox.shrink();

    final String yearText;
    final String title;
    final Widget cover;
    void Function() open;
    if (owned != null) {
      final o = owned;
      var year = 0;
      for (final s in o.songs) {
        if (s.year > year) year = s.year;
      }
      yearText = year > 0 ? '$year' : '${o.songs.length} songs';
      title = o.title;
      cover = AlbumArt(albumId: o.songs.first.albumId, size: 64, radius: 12);
      open = () {
        HapticFeedback.selectionClick();
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => AlbumPage(album: o)));
      };
    } else {
      final r = remote!;
      yearText = r.year != null ? '${r.year}' : _hubLabel(r.type);
      title = r.title;
      cover = ReleaseCover(release: r, owned: false, size: 64);
      open = () {
        HapticFeedback.selectionClick();
        final ownedTitles = local.map((s) => s.album.toLowerCase()).toSet();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ReleaseGallery(
              artistName: artistName,
              label: _hubLabel(r.type),
              items: hubItems ?? [r],
              ownedTitles: ownedTitles,
            ),
          ),
        );
      };
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: GestureDetector(
        onTap: open,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: paperRaised,
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
                    Text(
                      yearText,
                      style: const TextStyle(color: inkDim, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: inkDim),
            ],
          ),
        ),
      ),
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
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: const TextStyle(
                color: inkDim,
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

/// Collaborators: every other name sharing these songs, as sideways
/// links. The merge killed phantom pages; this keeps the people
/// reachable - tap opens their page (remote-only when needed).
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in names)
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    ArtistPage.openIfAbsent(context, n);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: paperRaised,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: ink.withValues(alpha: 0.08)),
                    ),
                    child: Text(
                      n,
                      style: const TextStyle(
                        color: ink,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
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
            style: const TextStyle(color: ink, fontSize: 15, height: 1.6),
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
/// No ranks, no expander - swipe left/right for more songs.
class _Popular extends ConsumerStatefulWidget {
  final AsyncValue<List<TopTrack>> top;
  final List<Song> local;
  final String artistName;

  const _Popular({
    required this.top,
    required this.local,
    required this.artistName,
  });

  @override
  ConsumerState<_Popular> createState() => _PopularState();
}

class _PopularState extends ConsumerState<_Popular> {
  late final PageController _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Song? _owned(String title) {
    final norm = _norm(title);
    for (final s in widget.local) {
      if (_norm(s.title) == norm) return s;
    }
    return null;
  }

  static String _norm(String t) =>
      t.toLowerCase().replaceAll(RegExp(r'\s*\(.*?\)\s*'), '').trim();

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    return widget.top.when(
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Popular'),
          Padding(
            padding: EdgeInsets.all(20),
            child: LinearProgressIndicator(color: archPink),
          ),
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
            SizedBox(
              height: 350,
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
                        isCurrent:
                            currentId != null &&
                            (currentId == _owned(track.title)?.id ||
                                currentId == -(track.rank + 1)),
                        onTap: () => _play(ref, context, track),
                        onOverflow: () => _trackActions(ref, context, track),
                      ),
                  ],
                ),
              ),
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
                              : inkDim.withValues(alpha: 0.3),
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

  Future<void> _play(
    WidgetRef ref,
    BuildContext context,
    TopTrack track,
  ) async {
    final handler = ref.read(audioHandlerProvider);
    final local = widget.local;
    final owned = _owned(track.title);
    if (owned != null) {
      await playAndOpen(ref, context, () => handler.playSong(owned, local));
      return;
    }
    final url = track.previewUrl;
    if (url == null || url.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Preview unavailable for this track')),
        );
      }
      return;
    }
    await playAndOpen(
      ref,
      context,
      () => handler.playPreview(
        uri: Uri.parse(url),
        title: track.title,
        artist: local.isEmpty ? widget.artistName : local.first.artist,
        album: track.albumTitle,
        coverUrl: track.coverUrl,
        previewId: -(track.rank + 1),
      ),
    );
  }

  void _trackActions(WidgetRef ref, BuildContext context, TopTrack track) {
    final owned = _owned(track.title);
    final tiles = <Widget>[
      ListTile(
        leading: const Icon(Icons.play_arrow_rounded, color: archPink),
        title: Text('Play ${track.title}', maxLines: 1),
        onTap: () {
          Navigator.of(context).pop();
          _play(ref, context, track);
        },
      ),
      if (owned != null)
        ListTile(
          leading: const Icon(Icons.album_rounded, color: ink),
          title: Text('Go to album - ${owned.album}', maxLines: 1),
          onTap: () {
            Navigator.of(context).pop();
            final albums = ref.read(albumsProvider);
            for (final a in albums) {
              if (normTitle(a.title) == normTitle(owned.album) &&
                  a.songs.any((s) => artistsOverlap(s.artist, owned.artist))) {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => AlbumPage(album: a)));
                return;
              }
            }
          },
        ),
      ListTile(
        leading: const Icon(Icons.share_rounded, color: ink),
        title: const Text('Share'),
        onTap: () {
          Navigator.of(context).pop();
          SharePlus.instance.share(
            ShareParams(text: '${track.title} - ${widget.artistName}'),
          );
        },
      ),
      // Discovery converts here: unowned tracks pull from providers.
      // Owned tracks never show this (restraint: no re-downloads).
      if (owned == null)
        ListTile(
          leading: const Icon(Icons.cloud_download_outlined, color: ink),
          title: Text('Download ${track.title}', maxLines: 1),
          onTap: () {
            Navigator.of(context).pop();
            _pull(ref, context, track);
          },
        ),
    ];
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Same house cascade as menus: rows arrive staggered.
            for (var i = 0; i < tiles.length; i++)
              CascadeIn(delayMs: i * 30, child: tiles[i]),
          ],
        ),
      ),
    );
  }

  /// Pull an unowned track through the priority-first download
  /// provider. Verify challenges open the sheet in context, then
  /// the same pull retries.
  Future<void> _pull(
      WidgetRef ref, BuildContext context, TopTrack track) async {
    final downloaders = [
      for (final p in ref.read(installedExtensionsProvider))
        if (p.enabled && p.roles.contains('download')) p,
    ];
    if (downloaders.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No download providers enabled')),
      );
      return;
    }
    final provider = downloaders.first;
    HapticFeedback.selectionClick();
    try {
      await pullTrack(
        provider: provider,
        title: track.title,
        artist: widget.artistName,
      );
      if (!context.mounted) return;
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${track.title} landed in your library')),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      ref.invalidate(songsProvider);
    } on NeedleException catch (e) {
      if (!context.mounted) return;
      if (e.code == 'verify-required') {
        final inlineUrl = e.message.startsWith('auth_url=')
            ? e.message.substring('auth_url='.length)
            : '';
        final url = await SessionGrant.resolveAuthUrl(
            provider.id, inlineUrl);
        if (!context.mounted) return;
        if (url == null || url.isEmpty) return;
        final granted = await handleVerifyRequired(
          context,
          extId: provider.id,
          displayName: provider.displayName,
          authUrl: url,
        );
        if (granted && context.mounted) _pull(ref, context, track);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(e.code == 'unavailable'
                ? 'Not available from ${provider.displayName}'
                : 'Download failed. Try again.')),
      );
      ArchLog.w('needle', 'artist pull failed: ${e.code}');
    }
  }
}

class _TopRow extends StatelessWidget {
  final TopTrack track;
  final Song? owned;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onOverflow;

  const _TopRow({
    required this.track,
    required this.owned,
    required this.isCurrent,
    required this.onTap,
    required this.onOverflow,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      onTap: onTap,
      leading: ClipRRect(
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
                  color: paperRaised,
                  child: const Icon(Icons.music_note, color: inkDim),
                ),
              )
            : Container(
                width: 52,
                height: 52,
                color: paperRaised,
                child: const Icon(Icons.music_note, color: inkDim),
              ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        style: TextStyle(
          color: isCurrent ? archPink : ink,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Row(
        children: [
          if (owned == null)
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
              style: const TextStyle(color: inkDim),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent)
            const NowBars()
          else
            Text(
              fmtDuration(track.duration),
              style: const TextStyle(color: inkDim),
            ),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, color: inkDim),
            onPressed: onOverflow,
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
          Padding(
            padding: EdgeInsets.all(20),
            child: LinearProgressIndicator(color: archPink),
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
        final ownedTitles = local.map((s) => s.album.toLowerCase()).toSet();
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
      widget.ownedTitles.contains(r.title.toLowerCase());

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
                            child: ReleaseCover(
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
                      child: ReleaseCover(
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
                          color: widget.open ? archPink : ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${widget.items.length}',
                        style: const TextStyle(color: inkDim, fontSize: 11),
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
