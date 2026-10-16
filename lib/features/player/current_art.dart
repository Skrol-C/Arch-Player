import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../library/song_row.dart';
import 'player_providers.dart';

/// Current-track art with the preview path first: streaming previews
/// carry albumId 0 but their cover rides the media-item artCacheFile
/// extra (cached by playPreview). Chain: file -> remote coverUrl ->
/// AlbumArt -> placeholder. Never blank while audio flows.
///
/// Two anti-bugs, both learned on device:
/// - `useLiveFile: false` for queue/row art: rows must paint their
///   OWN art, never the live item's file (otherwise every row
///   inherits the playing track's cover).
/// - Stale retention: while the new item has no file yet, keep the
///   previous image instead of flashing the placeholder. Keyed by
///   media-item id so same-id items never hold stale art.
class CurrentArt extends ConsumerStatefulWidget {
  final Song song;
  final double size;
  final double radius;
  final double iconSize;
  final bool fill;
  final bool useLiveFile;
  const CurrentArt({
    super.key,
    required this.song,
    required this.size,
    required this.radius,
    this.iconSize = 28,
    this.fill = false,
    this.useLiveFile = true,
  });

  @override
  ConsumerState<CurrentArt> createState() => _CurrentArtState();
}

class _CurrentArtState extends ConsumerState<CurrentArt> {
  String? _lastItemId;
  Widget? _retained;

  Song get _song => widget.song;

  @override
  Widget build(BuildContext context) {
    if (!widget.useLiveFile) return _fallback();
    final handler = ref.watch(audioHandlerProvider);
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.valueOrNull,
      builder: (context, snap) {
        final item = snap.data;
        final id = item?.id;
        final file = item?.extras?['artCacheFile'] as String?;
        if (file != null && file.isNotEmpty) {
          final body = Image.file(
            File(file),
            key: ValueKey(file),
            width: widget.fill ? null : widget.size,
            height: widget.fill ? null : widget.size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                _network(item, _fallback()) ?? _fallback(),
          );
          final framed = widget.fill
              ? body
              : ClipRRect(
                  borderRadius:
                      BorderRadius.circular(widget.radius),
                  child: body,
                );
          _lastItemId = id;
          _retained = framed;
          return framed;
        }
        // New item, no file yet: hold the previous image while
        // any remote art resolves underneath it. The hold is NEVER
        // overwritten by the fallback: a genuinely artless new item
        // keeps the old image until its own file or URL lands, and
        // same-id items fall through honestly.
        final hold = (id != null && id != _lastItemId) ? _retained : null;
        _lastItemId = id;
        final net = _network(item, hold ?? _fallback());
        if (net != null) {
          if (hold == null) _retained = net;
          return net;
        }
        if (hold != null) return hold;
        final fb = _fallback();
        _retained = fb;
        return fb;
      },
    );
  }

  /// Remote cover fallback for file-less items (expansion
  /// previews, evicted caches). The hold image shows while the
  /// network art resolves, so no frame flashes.
  Widget? _network(MediaItem? item, Widget hold) {
    final url = item?.extras?['coverUrl'] as String?;
    if (url == null || url.isEmpty) return null;
    final img = CachedNetworkImage(
      imageUrl: url,
      width: widget.fill ? null : widget.size,
      height: widget.fill ? null : widget.size,
      fit: BoxFit.cover,
      placeholder: (_, _) => hold,
      errorWidget: (_, _, _) => hold,
    );
    if (widget.fill) return img;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: img,
    );
  }

  Widget _fallback() {
    if (_song.albumId > 0) {
      return AlbumArt(
        albumId: _song.albumId,
        size: widget.size,
        radius: widget.radius,
        fill: widget.fill,
      );
    }
    final icon = Icon(
      CupertinoIcons.music_note,
      color: inkDim,
      size: widget.iconSize,
    );
    if (widget.fill) {
      return Container(color: paperRaised, child: Center(child: icon));
    }
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: icon,
    );
  }
}
