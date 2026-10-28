import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import 'song_row.dart' show FileArtImage;

/// One face per person.
///
/// A portrait must never be borrowed from a track's album art: a song
/// credited "Pitbull, A, B, C" would then paint the SAME cover for four
/// different people (the "Your artists" bug — every collaborator wore
/// the main artist's picture).
///
/// Order of truth:
///   1. the artist's own picture lane (`picFor`),
///   2. album art, but ONLY when this name is that song's primary
///      credit — the album cover genuinely represents that artist,
///   3. an honest monogram. Never a wrong face.
class ArtistPortrait extends ConsumerWidget {
  final String name;

  /// Representative song for the album-art fallback. Null = monogram
  /// unless the artist lane resolves.
  final Song? song;

  final double size;

  /// Corner radius; callers that want a circle clip the result.
  final double radius;

  /// Fill the parent box instead of sizing to [size].
  final bool fill;

  const ArtistPortrait({
    super.key,
    required this.name,
    this.song,
    this.size = 44,
    this.radius = 0,
    this.fill = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pic = ref.watch(artistPicProvider(name)).value;
    final body = (pic != null && pic.isNotEmpty)
        ? CachedNetworkImage(
            imageUrl: pic,
            fit: BoxFit.cover,
            memCacheWidth: (size * 3).round().clamp(120, 640),
            errorWidget: (_, _, _) => _fallback(context),
          )
        : _fallback(context);
    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: body,
    );
    if (fill) return SizedBox.expand(child: clipped);
    return SizedBox(width: size, height: size, child: clipped);
  }

  Widget _fallback(BuildContext context) {
    final s = song;
    // Album art only when the song is actually *this* artist's record.
    // A feature credit on someone else's track does not own that cover.
    final credited = s != null &&
        name.trim().isNotEmpty &&
        primaryArtist(s.artist).trim().toLowerCase() ==
            name.trim().toLowerCase();
    if (credited && (s.path.isNotEmpty || s.albumId > 0)) {
      return FileArtImage(
        path: s.path,
        albumId: s.albumId,
        size: size,
        radius: radius,
        fill: true,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Text(
        trimmed.isEmpty ? '?' : trimmed[0].toUpperCase(),
        style: TextStyle(
          color: archPink,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
