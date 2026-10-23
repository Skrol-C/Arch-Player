import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'library_providers.dart';
import 'album_page.dart' show AlbumPage;
import 'song_row.dart';
import '../shell/dock.dart';

/// One discography category, full grid. Owned in color + pink ring,
/// missing grayed. Owned tiles open the album; remote tiles say so
/// honestly (Needle owns downloads) - no dead tiles anywhere.
class ReleaseGallery extends ConsumerWidget {
  final String artistName;
  final String label;
  final List<ReleaseGroup> items;
  final Set<String> ownedTitles;

  const ReleaseGallery({
    super.key,
    required this.artistName,
    required this.label,
    required this.items,
    required this.ownedTitles,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('$artistName - $label')),
      body: DockScrollReporter(
        child: Stack(
          fit: StackFit.expand,
          children: [
            GridView.builder(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 140),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 24,
                // Measured extent, not a ratio: a ratio rounds and the
                // tile overflows by a fraction of a pixel on narrow
                // screens. Fits the year line when present.
                mainAxisExtent:
                    (MediaQuery.sizeOf(context).width - 56) / 2 + 48,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final r = items[i];
                final owned = ownedTitles.contains(r.title.toLowerCase());
                return FocalEntrance(
                  index: i,
                  child: GestureDetector(
                    onTap: () => _open(context, ref, r, owned),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ReleaseCover(
                            release: r,
                            owned: owned,
                            fill: true,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          r.title,
                          maxLines: 1,
                          style: TextStyle(
                            color: owned ? ink : inkDim,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (r.year != null)
                          Text(
                            '${r.year}',
                            style: const TextStyle(color: inkDim, fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const NowPlayingDock(),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref, ReleaseGroup r, bool owned) {
    if (owned) {
      for (final a in ref.read(albumsProvider)) {
        if (normTitle(a.title) == normTitle(r.title) &&
            a.songs.any(
              (s) =>
                  splitArtists(s.artist)
                      .any((n) => n.toLowerCase() == artistName.toLowerCase()),
            )) {
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => AlbumPage(album: a)));
          return;
        }
      }
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          owned
              ? 'Album moved - check Folders'
              : '${r.title} isn\u2019t on this device - downloads land with Needle',
        ),
      ),
    );
  }
}
