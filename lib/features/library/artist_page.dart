import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
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
/// unowned 30s previews), discography hubs that spring open inline.
/// Every block renders the moment it lands; no match = clean local page.
class ArtistPage extends ConsumerStatefulWidget {
  final String artistName;
  const ArtistPage({super.key, required this.artistName});

  @override
  ConsumerState<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistPage> {
  /// Currently sprung-open hub, if any.
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
            onFollow: () => ref.read(followedProvider.notifier).toggle(widget.artistName),
            onBack: () => Navigator.of(context).pop(),
          ),
          SliverToBoxAdapter(child: _Bio(bio: bio)),
          SliverToBoxAdapter(child: _TopSongs(top: top, local: local)),
          SliverToBoxAdapter(
            child: _Hubs(
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
      expandedHeight: 300,
      pinned: true,
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: LiquidGlassLens(
          style: const LiquidGlassStyle(
            shape: LiquidGlassShape.continuousRoundedRectangle(cornerRadius: 24, borderWidth: 1),
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
              left: 16,
              right: 16,
              bottom: 12,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FocalEntrance(
                          child: Text(name, style: Theme.of(context).textTheme.headlineLarge),
                        ),
                        Text('$count songs on device',
                            style: const TextStyle(color: archRed)),
                      ],
                    ),
                  ),
                  _FollowPill(followed: followed, onFollow: onFollow),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Follow lives on a floating glass pill, never in content.
class _FollowPill extends StatelessWidget {
  final bool followed;
  final VoidCallback onFollow;

  const _FollowPill({required this.followed, required this.onFollow});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassLens(
      style: LiquidGlassStyle(
        shape: const LiquidGlassShape.continuousRoundedRectangle(cornerRadius: 20, borderWidth: 1),
        appearance: LiquidGlassAppearance(
          color: followed ? archRed.withValues(alpha: 0.25) : const Color(0x14FFFFFF),
        ),
        refraction: const LiquidGlassRefraction(distortion: 0.08, distortionWidth: 10),
      ),
      child: TextButton(
        onPressed: onFollow,
        child: Text(followed ? '✓ Following' : '+ Follow',
            style: TextStyle(color: followed ? archRed : Colors.white)),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(color: archRed)),
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
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
            style: const TextStyle(color: inkTextDim),
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
          Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator(color: archRed)),
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
            borderRadius: BorderRadius.circular(8),
            child: Hero(
              tag: 'art-${track.title}',
              child: track.coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: track.coverUrl!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(
                        width: 48,
                        height: 48,
                        color: inkRaised,
                        child: const Icon(Icons.music_note, color: inkTextDim),
                      ),
                    )
                  : Container(
                      width: 48,
                      height: 48,
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

class _Hubs extends StatelessWidget {
  final AsyncValue<List<ReleaseGroup>> releases;
  final List<Song> local;
  final String? openHub;
  final ValueChanged<String> onHub;
  final String artistName;

  const _Hubs({
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
        padding: EdgeInsets.all(16),
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
            // The hub strip floats on glass; releases spring out beneath it.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: LiquidGlassLens(
                style: const LiquidGlassStyle(
                  shape: LiquidGlassShape.continuousRoundedRectangle(cornerRadius: 20, borderWidth: 1),
                  refraction: LiquidGlassRefraction(distortion: 0.08, distortionWidth: 10),
                ),
                child: Row(
                  children: [
                    for (final label in groups.keys)
                      Expanded(
                        child: _Hub(
                          label: label,
                          count: groups[label]!.length,
                          open: openHub == label,
                          onTap: () => onHub(label),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: Motion.overlay,
              curve: Motion.arrival,
              child: openHub != null && groups.containsKey(openHub)
                  ? _SpringOut(
                      label: openHub!,
                      items: groups[openHub!]!,
                      ownedTitles: ownedTitles,
                      artistName: artistName,
                    )
                  : const SizedBox.shrink(),
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

class _Hub extends StatelessWidget {
  final String label;
  final int count;
  final bool open;
  final VoidCallback onTap;

  const _Hub({required this.label, required this.count, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      child: Column(
        children: [
          Text(label,
              maxLines: 1,
              style: TextStyle(
                  color: open ? archRed : Colors.white, fontWeight: FontWeight.w600)),
          Text('$count', style: const TextStyle(color: inkTextDim, fontSize: 11)),
        ],
      ),
    );
  }
}

class _SpringOut extends StatelessWidget {
  final String label;
  final List<ReleaseGroup> items;
  final Set<String> ownedTitles;
  final String artistName;

  const _SpringOut({
    required this.label,
    required this.items,
    required this.ownedTitles,
    required this.artistName,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 150,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final r = items[i];
              final owned = ownedTitles.contains(r.title.toLowerCase());
              return FocalEntrance(
                index: i,
                child: Container(
                  width: 110,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 110,
                        decoration: BoxDecoration(
                          color: inkRaised,
                          borderRadius: BorderRadius.circular(12),
                          border: owned ? Border.all(color: archRed, width: 2) : null,
                        ),
                        foregroundDecoration: owned
                            ? null
                            : const BoxDecoration(
                                color: Color(0x99000000),
                                borderRadius: BorderRadius.all(Radius.circular(12)),
                              ),
                        child: Center(
                          child: r.artUrl != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: ColorFiltered(
                                    colorFilter: owned
                                        ? const ColorFilter.mode(
                                            Colors.transparent, BlendMode.multiply)
                                        : const ColorFilter.matrix(<double>[
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0, 0, 0, 0.6, 0,
                                          ]),
                                    child: CachedNetworkImage(
                                      imageUrl: r.artUrl!,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) => const Icon(
                                          Icons.album, color: Colors.white, size: 40),
                                    ),
                                  ),
                                )
                              : const Icon(Icons.album, color: inkTextDim, size: 40),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(r.title,
                          maxLines: 1,
                          style: TextStyle(
                              color: owned ? Colors.white : inkTextDim, fontSize: 12)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ReleaseGallery(
                  artistName: artistName, label: label, items: items, ownedTitles: ownedTitles),
            )),
            child: const Text('View all →'),
          ),
        ),
      ],
    );
  }
}
