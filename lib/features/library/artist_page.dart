import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import '../player/player_providers.dart';
import 'library_providers.dart';
import 'release_gallery.dart';
import 'song_row.dart';

/// Artist page: hero pic + name + bio, real top songs (owned full,
/// unowned 30s previews), discography as fanned cover stacks.
/// Every block renders the moment it lands; no match = clean local page.
class ArtistPage extends ConsumerStatefulWidget {
  final String artistName;
  const ArtistPage({super.key, required this.artistName});

  @override
  ConsumerState<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistPage> {
  /// Currently bloomed fan hub, if any.
  String? _openHub;

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
            count: local.length,
            imageUrl: pic.value,
            followed: followed.contains(widget.artistName),
            onFollow: () => _toggleFollow(ref, widget.artistName, followed.contains(widget.artistName)),
            onBack: () => Navigator.of(context).pop(),
          ),
          SliverToBoxAdapter(child: _Bio(bio: bio)),
          SliverToBoxAdapter(child: _TopSongs(top: top, local: local)),
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

  Future<void> _toggleFollow(WidgetRef ref, String artist, bool wasFollowed) async {
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
  final int count;
  final String? imageUrl;
  final bool followed;
  final VoidCallback onFollow;
  final VoidCallback onBack;

  const _Hero({
    required this.name,
    required this.count,
    required this.imageUrl,
    required this.followed,
    required this.onFollow,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 320,
      pinned: true,
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: LiquidGlassLens(
          style: const LiquidGlassStyle(
            shape: LiquidGlassShape.continuousRoundedRectangle(
                cornerRadius: 24, borderWidth: 1),
            refraction: LiquidGlassRefraction(distortion: 0.08, distortionWidth: 10),
          ),
          child: IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
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
                errorWidget: (_, _, _) => Container(color: inkRaised),
              )
            else
              Container(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0.5, 0.3),
                    radius: 1.1,
                    colors: [Color(0xFF3A0D18), ink],
                  ),
                ),
                child: Center(
                  child: Text(
                    name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: const TextStyle(color: archRed, fontSize: 96),
                  ),
                ),
              ),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.transparent, Color(0xE60B0B0D)],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 14,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FocalEntrance(
                          child: Text(name,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineLarge
                                  ?.copyWith(letterSpacing: -0.5)),
                        ),
                        const SizedBox(height: 2),
                        Text('$count songs on device',
                            style: const TextStyle(color: archRed)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onFollow,
                    iconSize: 28,
                    color: followed ? archRed : Colors.white,
                    icon: Icon(followed ? Icons.favorite : Icons.favorite_border),
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

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: archRed, fontWeight: FontWeight.w600)),
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
            style: const TextStyle(color: inkTextDim, height: 1.5),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _open = !_open),
          child: Text(_open ? 'Show less' : 'Read more'),
        ),
      ],
    );
  }
}

class _TopSongs extends ConsumerWidget {
  final AsyncValue<List<TopTrack>> top;
  final List<Song> local;

  const _TopSongs({required this.top, required this.local});

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
          _SectionTitle('Top songs'),
          Padding(padding: EdgeInsets.all(20), child: LinearProgressIndicator(color: archRed)),
        ],
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (tracks) {
        if (tracks.isEmpty) return const SizedBox.shrink();
        final current = ref.watch(currentSongProvider).value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('Top songs'),
            for (var i = 0; i < tracks.length; i++)
              _TopRow(
                track: tracks[i],
                owned: _owned(tracks[i].title),
                isCurrent: current != null &&
                    (current.title == tracks[i].title || current.id < 0),
                onTap: () => _play(ref, context, tracks[i]),
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
      await handler.playSong(owned, local);
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
    final preview = Song(
      id: -(track.rank + 1),
      uri: Uri.parse(url),
      title: track.title,
      album: track.albumTitle,
      artist: local.isEmpty ? '' : local.first.artist,
      albumId: 0,
      duration: const Duration(seconds: 30),
      year: 0,
      folderKey: 'preview',
      folderLabel: 'Preview',
    );
    await handler.playSong(preview, [preview]);
    opener.state = true;
  }
}

class _TopRow extends StatelessWidget {
  final TopTrack track;
  final Song? owned;
  final bool isCurrent;
  final VoidCallback onTap;

  const _TopRow(
      {required this.track, required this.owned, required this.isCurrent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      onTap: onTap,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            child: Text('${track.rank}',
                style: const TextStyle(color: inkTextDim, fontWeight: FontWeight.w600)),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Hero(
              tag: 'art-${track.title}',
              child: track.coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: track.coverUrl!,
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(
                        width: 52,
                        height: 52,
                        color: inkRaised,
                        child: const Icon(Icons.music_note, color: inkTextDim),
                      ),
                    )
                  : Container(
                      width: 52,
                      height: 52,
                      color: inkRaised,
                      child: const Icon(Icons.music_note, color: inkTextDim),
                    ),
            ),
          ),
        ],
      ),
      title: Text(track.title,
          maxLines: 1, style: TextStyle(color: isCurrent ? archRed : Colors.white)),
      subtitle: Row(
        children: [
          if (owned == null)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: archRed.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('PREVIEW',
                  style: TextStyle(color: archRed, fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          Expanded(
            child: Text(track.albumTitle, maxLines: 1, style: const TextStyle(color: inkTextDim)),
          ),
        ],
      ),
      trailing: isCurrent
          ? const NowBars()
          : Text(fmtDuration(track.duration), style: const TextStyle(color: inkTextDim)),
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
      loading: () => const Padding(
        padding: EdgeInsets.all(20),
        child: LinearProgressIndicator(color: archRed),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final groups = <String, List<ReleaseGroup>>{};
        for (final r in list) {
          groups.putIfAbsent(_labelOf(r.type), () => []).add(r);
        }
        final ownedTitles = local.map((s) => s.album.toLowerCase()).toSet();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('Discography'),
            SizedBox(
              height: 210,
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
          width: 190,
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
                      onLongPress: widget.onToggle,
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
                              color: widget.open ? archRed : Colors.white,
                              fontWeight: FontWeight.w600)),
                      Text('${widget.items.length}',
                          style: const TextStyle(color: inkTextDim, fontSize: 11)),
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

/// One release cover: known art URL first, else CAA resolve by MBID,
/// else the designed monogram fallback. Owned = color + red ring.
class ReleaseCover extends StatelessWidget {
  final ReleaseGroup release;
  final bool owned;
  final double size;

  const ReleaseCover({super.key, required this.release, required this.owned, required this.size});

  @override
  Widget build(BuildContext context) {
    final direct = release.artUrl;
    final mbid = release.rgMbid;
    final body = (direct != null)
        ? _art(direct)
        : (mbid != null ? _CaaCover(mbid: mbid) : _fallback());
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: owned ? Border.all(color: archRed, width: 2) : null,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColorFiltered(
          colorFilter: owned
              ? const ColorFilter.mode(Colors.transparent, BlendMode.multiply)
              : const ColorFilter.matrix(<double>[
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0, 0, 0, 0.6, 0,
                ]),
          child: body,
        ),
      ),
    );
  }

  Widget _art(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      errorWidget: (_, _, _) => _fallback(),
    );
  }

  Widget _fallback() {
    return Container(
      color: inkRaised,
      child: Center(
        child: Text(
          release.title.isEmpty ? '?' : release.title[0].toUpperCase(),
          style: const TextStyle(color: archRed, fontSize: 40, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _CaaCover extends ConsumerWidget {
  final String mbid;
  const _CaaCover({required this.mbid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(releaseCoverProvider(mbid)).value;
    if (url == null) {
      return Container(
        color: inkRaised,
        child: const Center(child: Icon(Icons.album, color: inkTextDim, size: 40)),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      errorWidget: (_, _, _) => Container(
        color: inkRaised,
        child: const Center(child: Icon(Icons.album, color: inkTextDim, size: 40)),
      ),
    );
  }
}
