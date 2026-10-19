import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../needle/catalog_store.dart';
import '../needle/needle_store.dart';
import '../shell/dock.dart';

/// Catalog: every Needle pull, filed with date, provider and quality.
/// Moved out of the Needle hub — the hub is queue-only now. Albums
/// group; everything else is a track.
class CatalogPage extends ConsumerWidget {
  const CatalogPage({super.key});

  static void open(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const CatalogPage()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: paper,
      body: Stack(
        children: [
          DockScrollReporter(
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 64)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: paperRaised,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: const Icon(
                              CupertinoIcons.chevron_left,
                              color: ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Catalog',
                            style: TextStyle(
                              fontFamily: 'ArchSerif',
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                const SliverToBoxAdapter(child: _CatalogPane()),
                const SliverToBoxAdapter(child: SizedBox(height: 140)),
              ],
            ),
          ),
          const NowPlayingDock(),
        ],
      ),
    );
  }
}

class _CatalogPane extends ConsumerWidget {
  const _CatalogPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(catalogProvider);
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(24, 24, 24, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nothing filed yet.',
              style: TextStyle(
                fontFamily: 'ArchSerif',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Every pull files here with its date, provider and quality — albums and tracks, playlists later.',
              style: TextStyle(color: inkDim, height: 1.5),
            ),
          ],
        ),
      );
    }
    final albums = <String, List<CatalogEntry>>{};
    final singles = <CatalogEntry>[];
    for (final e in entries) {
      // Release type decides, not the album tag: a single carries an
      // album name but was filed (and should read) as a track.
      if (e.isAlbum) {
        albums.putIfAbsent(e.album, () => []).add(e);
      } else {
        singles.add(e);
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (albums.isNotEmpty) ...[
            const _GroupHeader(label: 'Albums'),
            for (final name in albums.keys)
              _AlbumCard(name: name, tracks: albums[name]!),
          ],
          if (singles.isNotEmpty) ...[
            const _GroupHeader(label: 'Tracks'),
            for (final e in singles) ...[
              _EntryRow(entry: e),
              const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'ArchSerif',
          fontSize: 24,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final String name;
  final List<CatalogEntry> tracks;
  const _AlbumCard({required this.name, required this.tracks});

  @override
  Widget build(BuildContext context) {
    final first = tracks.first;
    final date = DateTime.fromMillisecondsSinceEpoch(first.landedMs);
    final when =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return Container(
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: first.art.isEmpty
                    ? Container(
                        width: 56,
                        height: 56,
                        color: paper,
                        child: const Icon(Icons.album_outlined, color: inkDim),
                      )
                    : CachedNetworkImage(
                        memCacheWidth: 112,
                        memCacheHeight: 112,
                        maxWidthDiskCache: 512,
                        maxHeightDiskCache: 512,
                        imageUrl: first.art,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => Container(
                          width: 56,
                          height: 56,
                          color: paper,
                          child: const Icon(
                            Icons.album_outlined,
                            color: inkDim,
                          ),
                        ),
                      ),
              ),
              title: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                '${first.artist}  |  ${tracks.length} tracks  |  $when',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: inkDim, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  final CatalogEntry entry;
  const _EntryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final date = DateTime.fromMillisecondsSinceEpoch(entry.landedMs);
    final when =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final quality = NeedleQualitiesLabel.of(entry.quality);
    return Container(
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: entry.art.isEmpty
                ? Container(
                    width: 56,
                    height: 56,
                    color: paper,
                    child: const Icon(Icons.music_note_rounded, color: inkDim),
                  )
                : CachedNetworkImage(
                    memCacheWidth: 112,
                    memCacheHeight: 112,
                    maxWidthDiskCache: 512,
                    maxHeightDiskCache: 512,
                    imageUrl: entry.art,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => Container(
                      width: 56,
                      height: 56,
                      color: paper,
                      child: const Icon(
                        Icons.music_note_rounded,
                        color: inkDim,
                      ),
                    ),
                  ),
          ),
          title: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          subtitle: Text(
            [
              entry.artist,
              entry.provider,
              quality,
              when,
            ].where((String s) => s.isNotEmpty).join('  |  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: inkDim, fontSize: 13),
          ),
        ),
      ),
    );
  }
}
