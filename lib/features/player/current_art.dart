import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../library/song_row.dart';
import 'player_providers.dart';

/// Current-track art with the preview path first: streaming previews
/// carry albumId 0 but their cover rides the media-item artCacheFile
/// extra (cached by playPreview). File image when present, else the
/// usual AlbumArt-or-placeholder. Never blank while audio flows.
class CurrentArt extends ConsumerWidget {
  final Song song;
  final double size;
  final double radius;
  final double iconSize;
  final bool fill;
  const CurrentArt({
    super.key,
    required this.song,
    required this.size,
    required this.radius,
    this.iconSize = 28,
    this.fill = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.watch(audioHandlerProvider);
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.valueOrNull,
      builder: (context, snap) {
        final file = snap.data?.extras?['artCacheFile'] as String?;
        if (file != null && file.isNotEmpty) {
          final body = Image.file(
            File(file),
            width: fill ? null : size,
            height: fill ? null : size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _fallback(),
          );
          if (fill) return body;
          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: body,
          );
        }
        return _fallback();
      },
    );
  }

  Widget _fallback() {
    if (song.albumId > 0) {
      return AlbumArt(
        albumId: song.albumId,
        size: size,
        radius: radius,
        fill: fill,
      );
    }
    final icon = Icon(
      CupertinoIcons.music_note,
      color: inkDim,
      size: iconSize,
    );
    if (fill) {
      return Container(color: paperRaised, child: Center(child: icon));
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: icon,
    );
  }
}
