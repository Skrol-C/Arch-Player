import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'library_providers.dart';
import 'library_screen.dart' show AlbumDetail;
import 'release_gallery.dart';
import 'song_row.dart';

/// Artist page: SpotiFLAC anatomy in our skin — full-bleed hero with
/// action row, featured album card, Popular top 5 + expander, Albums rail
/// with counts, fan decks for the long tail, About block.
/// Every block renders the moment it lands; no match = clean local page.
class ArtistPage extends ConsumerStatefulWidget {
  final String artistName;
  const ArtistPage({super.key, required this.artistName});

  /// Artists currently on the navigation stack. Pushing the same artist
  /// twice stacked identical routes — guard it.
  static final Set<String> _open = {};

  static bool openIfAbsent(BuildContext context, String artistName) {
    if (_open.contains(artistName)) return false;
    ArchLog.i('nav', 'artist open: $artistName');
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ArtistPage(artistName: artistName),
    ));
    return true;
  }

  @override
  ConsumerState<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistPage> {
  /// Currently bloomed fan hub, if any.
  String? _openHub;
  bool _showAllPopular = false;

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
    final local = songs.where((s) => s.artist == widget.artistName).toList();
    final pic = ref.watch(artistPicProvider(widget.artistName));
    final bio = ref.watch(artistBioProvider(widget.artistName));
    final top = ref.watch(artistTopProvider(widget.artistName));
    final releases = ref.watch(artistReleasesProvider(widget.artistName));
    final followed = ref.watch(followedProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          _Hero(
            name: widget.artistName,
            local: local,
            imageUrl: pic.value,
            followed: followed.contains(widget.artistName),
            onFollow: () => _toggleFollow(widget.artistName, followed.contains(widget.artistName)),
            onBack: () => Navigator.of(context).pop(),
            onShare: () => SharePlus.instance.share(
              ShareParams(text: widget.artistName),
            ),
          ),
          SliverToBoxAdapter(child: _Bio(bio: bio)),
          SliverToBoxAdapter(
            child: _Popular(
              top: top,
              local: local,
              artistName: widget.artistName,
              expanded: _showAllPopular,
              onExpand: () => setState(() => _showAllPopular = !_showAllPopular),
            ),
          ),
          SliverToBoxAdapter(
            child: _FanRow(
              releases: releases,
              local: local,
              openHub: _openHub,
              onHub: (label) => setState(() => _openHub = _openHub == label ? null : label),
              artistName: widget.artistName,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Future<void> _toggleFollow(String artist, bool wasFollowed) async {
    HapticFeedback.selectionClick();
    await ref.read(followedProvider.notifier).toggle(artist);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(wasFollowed ? 'Unfollowed $artist' : 'Following $artist — new releases will find you'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  final String name;
  final List<Song> local;
  final String? imageUrl;
  final bool followed;
  final VoidCallback onFollow;
  final VoidCallback onBack;
  final VoidCallback onShare;

  const _Hero({
    required this.name,
    required this.local,
    required this.imageUrl,
    required this.followed,
    required this.onFollow,
    required this.onBack,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 380,
      pinned: true,
      backgroundColor: paper,
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: LiquidGlassLens(
          style: const LiquidGlassStyle(
            shape: LiquidGlassShape.continuousRoundedRectangle(
                cornerRadius: 24, borderWidth: 1),
            refraction: LiquidGlassRefraction(distortion: 0.08, distortionWidth: 10),
          ),
          child: IconButton(
              onPressed: onBack, icon: const Icon(Icons.arrow_back, color: ink)),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl != null)
              CachedNetworkImage(
                imageUrl: imageUrl!,
                fit: BoxFit.cover,
                memCacheWidth: 800,
                errorWidget: (_, _, _) => Container(color: paperRaised),
              )
            else
              Container(
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
              ),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black38, Color(0xE6000000)],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FocalEntrance(
                    child: Text(name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5)),
                  ),
                  const SizedBox(height: 4),
                  Text('${local.length} song${local.length == 1 ? '' : 's'} on device',
                      style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  _ActionRow(
                    local: local,
                    followed: followed,
                    onFollow: onFollow,
                    onShare: onShare,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Share · big play · follow. No dead download control until Needle exists.
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
            final opener = ref.read(playerOpenProvider.notifier);
            await playGuarded(context, () => handler.playSong(local.first, local));
            opener.state = true;
          },
          child: Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
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

  const _RoundButton({required this.icon, required this.onTap, this.color = Colors.white});

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
          Text(text,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: ink)),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text('$count', style: const TextStyle(color: inkDim, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ],
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
            style: const TextStyle(color: ink, fontSize: 15, height: 1.6),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _open = !_open),
          child: Text(_open ? 'Show less' : 'Read more',
              style: const TextStyle(color: archPink, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _Popular extends ConsumerWidget {
  final AsyncValue<List<TopTrack>> top;
  final List<Song> local;
  final String artistName;
  final bool expanded;
  final VoidCallback onExpand;

  const _Popular({
    required this.top,
    required this.local,
    required this.artistName,
    required this.expanded,
    required this.onExpand,
  });

  Song? _owned(String title) {
    final norm = _norm(title);
    for (final s in local) {
      if (_norm(s.title) == norm) return s;
    }
    return null;
  }

  static String _norm(String t) =>
      t.toLowerCase().replaceAll(RegExp(r'\s*\(.*?\)\s*'), '').trim();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return top.when(
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Popular'),
          Padding(padding: EdgeInsets.all(20), child: LinearProgressIndicator(color: archPink)),
        ],
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (tracks) {
        if (tracks.isEmpty) return const SizedBox.shrink();
        final shown = expanded ? tracks.take(10).toList() : tracks.take(5).toList();
        final currentId = ref.watch(currentSongProvider).value?.id;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle('Popular', count: tracks.length),
            for (var i = 0; i < shown.length; i++)
              _TopRow(
                track: shown[i],
                owned: _owned(shown[i].title),
                isCurrent: currentId != null &&
                    (currentId == _owned(shown[i].title)?.id ||
                        currentId == -(shown[i].rank + 1)),
                onTap: () => _play(ref, context, shown[i]),
                onOverflow: () => _trackActions(ref, context, shown[i]),
              ),
            if (tracks.length > 5)
              Center(
                child: TextButton(
                  onPressed: onExpand,
                  child: Text(expanded ? 'Show less' : 'Show all ${tracks.length}',
                      style: const TextStyle(color: archPink, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _play(WidgetRef ref, BuildContext context, TopTrack track) async {
    final handler = ref.read(audioHandlerProvider);
    final opener = ref.read(playerOpenProvider.notifier);
    final owned = _owned(track.title);
    if (owned != null) {
      await playGuarded(context, () => handler.playSong(owned, local));
      opener.state = true;
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
    await playGuarded(
        context,
        () => handler.playPreview(
              uri: Uri.parse(url),
              title: track.title,
              artist: local.isEmpty ? artistName : local.first.artist,
              album: track.albumTitle,
              coverUrl: track.coverUrl,
              previewId: -(track.rank + 1),
            ));
    opener.state = true;
  }

  void _trackActions(WidgetRef ref, BuildContext context, TopTrack track) {
    final owned = _owned(track.title);
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                title: Text('Go to album · ${owned.album}', maxLines: 1),
                onTap: () {
                  Navigator.of(context).pop();
                  final albums = ref.read(albumsProvider);
                  for (final a in albums) {
                    if (a.title == owned.album && a.artist == owned.artist) {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => AlbumDetail(album: a),
                      ));
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
                SharePlus.instance.share(ShareParams(text: '${track.title} — $artistName'));
              },
            ),
          ],
        ),
      ),
    );
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
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            child: Text('${track.rank}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ink)),
          ),
          ClipRRect(
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
        ],
      ),
      title: Text(track.title,
          maxLines: 1, style: TextStyle(color: isCurrent ? archPink : ink, fontWeight: FontWeight.w600)),
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
              child: const Text('PREVIEW',
                  style: TextStyle(color: archPink, fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          Expanded(
            child: Text(track.albumTitle, maxLines: 1, style: const TextStyle(color: inkDim)),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent) const NowBars()
          else Text(fmtDuration(track.duration), style: const TextStyle(color: inkDim)),
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
          Padding(padding: EdgeInsets.all(20), child: LinearProgressIndicator(color: archPink)),
        ],
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final groups = <String, List<ReleaseGroup>>{};
        for (final r in list) {
          groups.putIfAbsent(_labelOf(r.type), () => []).add(r);
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

  static String _labelOf(String type) => switch (type) {
        'album' => 'Albums',
        'single' || 'ep' => 'Singles & EPs',
        'live' => 'Live',
        'compilation' => 'Compilations',
        _ => 'More',
      };
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

class _FanStackState extends State<_FanStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
    if (widget.open) _c.value = 1;
  }

  @override
  void didUpdateWidget(_FanStack old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      if (widget.open) {
        _c.animateTo(1, curve: Curves.easeOutBack, duration: const Duration(milliseconds: 450));
      } else {
        _c.animateTo(0, curve: Motion.settle, duration: const Duration(milliseconds: 220));
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool _owned(ReleaseGroup r) => widget.ownedTitles.contains(r.title.toLowerCase());

  void _gallery(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReleaseGallery(
          artistName: widget.artistName,
          label: widget.label,
          items: widget.items,
          ownedTitles: widget.ownedTitles),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Up to 5 covers in the fan; the count badge covers the rest.
    final shown = widget.items.take(5).toList();
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Motion.reduced(context) ? (widget.open ? 1.0 : 0.0) : _c.value;
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
                        offset: Offset((i.isEven ? -1 : 1) * i * 13.0 * t, -i * 3.0 * t),
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
                      onTap: widget.open ? () => _gallery(context) : widget.onToggle,
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
                      Text(widget.label,
                          style: TextStyle(
                              color: widget.open ? archPink : ink,
                              fontWeight: FontWeight.w600)),
                      Text('${widget.items.length}',
                          style: const TextStyle(color: inkDim, fontSize: 11)),
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
