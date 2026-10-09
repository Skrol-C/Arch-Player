import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import '../player/player_providers.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Artist page: local top songs + enriched pic, discography, bio.
/// Each enriched block renders the moment it lands. Every block degrades:
/// no match = clean local-only page, never broken.
class ArtistPage extends ConsumerStatefulWidget {
  final String artistName;
  const ArtistPage({super.key, required this.artistName});

  @override
  ConsumerState<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistPage> {
  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(songsProvider).value ?? [];
    final local = songs.where((s) => s.artist == widget.artistName).toList();
    final pic = ref.watch(artistPicProvider(widget.artistName));
    final bio = ref.watch(artistBioProvider(widget.artistName));
    final releases = ref.watch(artistReleasesProvider(widget.artistName));
    final followed = ref.watch(followedProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Artist')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Header(
            name: widget.artistName,
            count: local.length,
            imageUrl: pic.value,
            followed: followed.contains(widget.artistName),
            onFollow: () => ref.read(followedProvider.notifier).toggle(widget.artistName),
          ),
          _SectionTitle('Top songs'),
          for (final s in (List<Song>.from(local)..sort((a, b) => a.title.compareTo(b.title))).take(10))
            SongRow(
              song: s,
              art: AlbumArt(albumId: s.albumId),
              isCurrent: ref.watch(currentSongProvider).value?.id == s.id,
              onTap: () async {
                final handler = ref.read(audioHandlerProvider);
                final opener = ref.read(playerOpenProvider.notifier);
                await handler.playSong(s, local);
                opener.state = true;
              },
            ),
          _Discography(releases: releases, local: local),
          _Bio(bio: bio),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String name;
  final int count;
  final String? imageUrl;
  final bool followed;
  final VoidCallback onFollow;

  const _Header(
      {required this.name,
      required this.count,
      required this.imageUrl,
      required this.followed,
      required this.onFollow});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 48,
            backgroundColor: inkRaised,
            backgroundImage: imageUrl != null ? CachedNetworkImageProvider(imageUrl!) : null,
            onBackgroundImageError: imageUrl != null ? (_, _) {} : null,
            child: imageUrl == null
                ? Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: const TextStyle(color: archRed, fontSize: 36))
                : null,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: Theme.of(context).textTheme.headlineSmall),
                Text('$count songs on device', style: const TextStyle(color: archRed)),
              ],
            ),
          ),
          FilledButton.tonal(
            onPressed: onFollow,
            child: Text(followed ? 'Following' : 'Follow'),
          ),
        ],
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
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: archRed)),
    );
  }
}

class _Discography extends StatelessWidget {
  final AsyncValue<List<ReleaseGroup>> releases;
  final List<Song> local;

  const _Discography({required this.releases, required this.local});

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
        final ownedTitles = local.map((s) => s.album.toLowerCase()).toSet();
        final groups = <String, List<ReleaseGroup>>{};
        for (final r in list) {
          groups.putIfAbsent(_labelOf(r.type), () => []).add(r);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle('Discography'),
            for (final entry in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(entry.key, style: Theme.of(context).textTheme.titleSmall),
              ),
              SizedBox(
                height: 150,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: entry.value.length,
                  itemBuilder: (context, i) {
                    final r = entry.value[i];
                    final owned = ownedTitles.contains(r.title.toLowerCase());
                    return Container(
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
                                              Icons.album,
                                              color: Colors.white,
                                              size: 40),
                                        ),
                                      ),
                                    )
                                  : ColorFiltered(
                                      colorFilter: owned
                                          ? const ColorFilter.mode(
                                              Colors.transparent, BlendMode.multiply)
                                          : const ColorFilter.matrix(<double>[
                                              0.2126, 0.7152, 0.0722, 0, 0,
                                              0.2126, 0.7152, 0.0722, 0, 0,
                                              0.2126, 0.7152, 0.0722, 0, 0,
                                              0, 0, 0, 0.6, 0,
                                            ]),
                                      child: const Icon(Icons.album,
                                          color: Colors.white, size: 40),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(r.title,
                              maxLines: 1,
                              style: TextStyle(
                                  color: owned ? Colors.white : inkTextDim, fontSize: 12)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
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
        _SectionTitle('About'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(text, style: const TextStyle(color: inkTextDim)),
        ),
      ],
    );
  }
}
