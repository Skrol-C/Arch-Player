import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import 'album_page.dart';
import 'song_row.dart';

/// Shared album tile for the hub and the Albums index. `subtitle`
/// is caller-owned (year on the hub, artist on the index) so the
/// geometry stays identical everywhere.
class AlbumGridCard extends StatelessWidget {
  final Album album;
  final String subtitle;

  const AlbumGridCard({super.key, required this.album, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final rep = album.songs.firstWhere(
      (s) => s.path.isNotEmpty,
      orElse: () => album.songs.first,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AlbumPage(album: album)),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: rep.path.isNotEmpty
                  ? FileArtImage(
                      path: rep.path,
                      albumId: rep.albumId,
                      size: 160,
                      radius: 18,
                    )
                  : Container(color: paperRaised),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: inkDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// List-mode album row: cover thumb, title, artist, chevron.
class AlbumRow extends StatelessWidget {
  final Album album;

  const AlbumRow({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    final rep = album.songs.firstWhere(
      (s) => s.path.isNotEmpty,
      orElse: () => album.songs.first,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AlbumPage(album: album)),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 56,
                child: rep.path.isNotEmpty
                    ? FileArtImage(
                        path: rep.path,
                        albumId: rep.albumId,
                        size: 140,
                        radius: 10,
                      )
                    : Container(color: paperRaised),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    album.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: inkDim, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(CupertinoIcons.chevron_right, color: inkDim, size: 16),
          ],
        ),
      ),
    );
  }
}
