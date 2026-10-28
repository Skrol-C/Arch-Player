import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/badges.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
import 'data/art_previews.dart';
import 'data/library_repository.dart';

String fmtDuration(Duration d) {
  if (d.inMilliseconds <= 0) return '--:--';
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Album art over our own channel, memory-cached. Falls back to a disc.
/// Sized for rows; pass fill for grid cells. [detail] pulls the large
/// bucket (player hero); everything else takes small - 512px covers
/// 3x density at every row, rail, and grid size in the app.
class AlbumArt extends StatelessWidget {
  final int albumId;
  final double size;
  final double radius;
  final bool fill;
  final bool detail;

  const AlbumArt({
    super.key,
    required this.albumId,
    this.size = 52,
    this.radius = 12,
    this.fill = false,
    this.detail = false,
  });

  @override
  Widget build(BuildContext context) {
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest),
          FutureBuilder(
            future: ArtCache.of(
              albumId,
              detail ? ArtBucket.large : ArtBucket.small,
            ),
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes != null && bytes.isNotEmpty) {
                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const _DiscIcon(),
                );
              }
              return const _DiscIcon();
            },
          ),
        ],
      ),
    );
    if (fill) return body;
    return SizedBox(width: size, height: size, child: body);
  }
}

/// File art through the preview store, falling back to the album
/// row. Same API shape as [AlbumArt] so call sites swap one line:
/// every surface that knows a file path paints the file's own art
/// instead of depending on MediaStore album art (missing for fresh
/// pulls). The future is memoized per path — a rebuild never
/// refires the read, which is what the placeholder flicker was.
class FileArtImage extends StatefulWidget {
  final String path;
  final int albumId;
  final double size;
  final double radius;
  final bool fill;
  final bool detail;

  const FileArtImage({
    super.key,
    required this.path,
    required this.albumId,
    this.size = 52,
    this.radius = 12,
    this.fill = false,
    this.detail = false,
  });

  @override
  State<FileArtImage> createState() => _FileArtImageState();
}

class _FileArtImageState extends State<FileArtImage> {
  Future<String?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.path.isEmpty ? null : ArtPreviews.previewFor(widget.path);
  }

  @override
  void didUpdateWidget(covariant FileArtImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _future = widget.path.isEmpty
          ? null
          : ArtPreviews.previewFor(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fb = AlbumArt(
      albumId: widget.albumId,
      size: widget.size,
      radius: widget.radius,
      fill: widget.fill,
      detail: widget.detail,
    );
    if (_future == null) return fb;
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snap) {
        final p = snap.data;
        if (p == null || p.isEmpty) return fb;
        final img = Image.file(
          File(p),
          fit: BoxFit.cover,
          cacheWidth: widget.detail
              ? 1400
              : widget.fill
              ? 700
              : (widget.size * 3).round().clamp(200, 700),
          errorBuilder: (_, _, _) => fb,
        );
        final body = ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: img,
        );
        if (widget.fill) return body;
        return SizedBox(width: widget.size, height: widget.size, child: body);
      },
    );
  }
}

class _DiscIcon extends StatelessWidget {
  const _DiscIcon();

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.music_note,
        color: Theme.of(context).colorScheme.onSurfaceVariant);
  }
}

/// One release cover: known art URL first, else CAA resolve by MBID,
/// else the designed monogram fallback. Owned = color + pink ring.
class ReleaseCover extends StatelessWidget {
  final ReleaseGroup release;
  final bool owned;
  final double size;
  final bool fill;

  const ReleaseCover({
    super.key,
    required this.release,
    required this.owned,
    this.size = 118,
    this.fill = false,
  });

  @override
  Widget build(BuildContext context) {
    final direct = release.artUrl;
    final mbid = release.rgMbid;
    final Widget body = (direct != null)
        ? _art(context, direct)
        : (mbid != null ? _CaaCover(mbid: mbid) : _fallback(context));
    final framed = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: owned ? Border.all(color: archPink, width: 2) : null,
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColorFiltered(
          colorFilter: owned
              ? const ColorFilter.mode(Colors.transparent, BlendMode.multiply)
              : const ColorFilter.matrix(<double>[
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0.55,
                  0,
                ]),
          child: body,
        ),
      ),
    );
    if (fill) return SizedBox.expand(child: framed);
    return SizedBox(width: size, height: size, child: framed);
  }

  Widget _art(BuildContext context, String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: 600,
      errorWidget: (_, _, _) => _fallback(context),
    );
  }

  Widget _fallback(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          release.title.isEmpty ? '?' : release.title[0].toUpperCase(),
          style: const TextStyle(
            color: archPink,
            fontSize: 40,
            fontWeight: FontWeight.w700,
          ),
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
            child: Icon(Icons.album,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 40)),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: 600,
      errorWidget: (_, _, _) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
            child: Icon(Icons.album,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 40)),
      ),
    );
  }
}

class SongRow extends StatelessWidget {
  final Song song;

  /// Leading art. Null = the file's own art via the preview store
  /// (album row underneath), so rows never depend on callers
  /// threading art through.
  final Widget? art;
  final bool isCurrent;
  final VoidCallback onTap;

  /// Trailing `...`. Null hides it (contexts where a menu has no
  /// home). [onMoreAt] gets the button's own context so the menu
  /// anchors to the row — preferred. Plain [onMore] keeps working
  /// for callers whose context already anchors.
  final VoidCallback? onMore;
  final void Function(BuildContext)? onMoreAt;

  /// Hold = same menu as `...` (list + grid parity). Null = tap only.
  final VoidCallback? onHold;

  /// Select mode: non-null shows a leading check circle instead of
  /// art. Tap toggles through [onTap]; [onMore]/[onMoreAt] should be
  /// null while selecting.
  final bool? selected;

  /// Playlists already holding this song, for the select-mode
  /// containment badge. Null/empty = no badge. Callers pass it only
  /// while selecting — normal browsing stays clean.
  final List<String>? containedIn;

  const SongRow({
    super.key,
    required this.song,
    this.art,
    required this.isCurrent,
    required this.onTap,
    this.onMore,
    this.onMoreAt,
    this.onHold,
    this.selected,
    this.containedIn,
  });

  @override
  Widget build(BuildContext context) {
    final sel = selected;
    return ListTile(
      onTap: sel == null
          ? onTap
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      onLongPress: sel != null
          ? null
          : onHold == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onHold!();
            },
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: SizedBox(
        width: 52,
        height: 52,
        child: sel == null
            ? art ?? FileArtImage(path: song.path, albumId: song.albumId)
            : CheckDot(checked: sel),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        style: TextStyle(
            color: isCurrent
                ? archPink
                : Theme.of(context).colorScheme.onSurface),
      ),
      subtitle: containedIn == null || containedIn!.isEmpty
          ? Text(
              song.artist,
              maxLines: 1,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            )
          : Row(
              children: [
                Flexible(
                  child: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 6),
                ContainedBadge(names: containedIn!),
              ],
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent) NowBars(song: song),
          const SizedBox(width: 8),
          Text(
            fmtDuration(song.duration),
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (onMore != null || onMoreAt != null)
            Builder(
              builder: (btnContext) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  if (onMoreAt != null) {
                    onMoreAt!(btnContext);
                  } else {
                    onMore!();
                  }
                },
                child: SizedBox(
                  width: 40,
                  height: 52,
                  child: Icon(CupertinoIcons.ellipsis,
                      color: Theme.of(btnContext)
                          .colorScheme
                          .onSurfaceVariant,
                      size: 18),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CheckDot extends StatelessWidget {
  final bool checked;
  const CheckDot({super.key, required this.checked});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: checked ? archPink : Colors.transparent,
          border: Border.all(
            color: checked
                ? archPink
                : Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.5),
            width: 2,
          ),
        ),
        child: checked
            ? const Icon(
                CupertinoIcons.checkmark,
                color: Colors.white,
                size: 16,
              )
            : null,
      ),
    );
  }
}

/// Fake playing indicator, smooth edition: five bars driven like a
/// VU meter — each bar re-rolls its target on its own staggered
/// clock, snaps up fast and falls slow. Incommensurate timings mean
/// the pattern never visibly loops, so it reads as music instead of
/// a wave. Reduced motion parks it mid-pose.
class NowBars extends StatefulWidget {
  final Song? song;
  const NowBars({super.key, this.song});

  @override
  State<NowBars> createState() => _NowBarsState();
}

class _NowBarsState extends State<NowBars> with SingleTickerProviderStateMixin {
  static const _bars = 5;
  late final Ticker _ticker;
  final _rand = math.Random();
  final _value = List<double>.filled(_bars, 0.2);
  final _target = List<double>.filled(_bars, 0.2);
  final _retargetAt = List<Duration>.filled(_bars, Duration.zero);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    if (Motion.reduced(context)) {
      for (var i = 0; i < _bars; i++) {
        _value[i] += (0.3 - _value[i]) * 0.2;
      }
    } else {
      for (var i = 0; i < _bars; i++) {
        if (elapsed >= _retargetAt[i]) {
          // Biased low with occasional peaks, like real dynamics.
          final r = _rand.nextDouble();
          _target[i] = 0.05 + 0.95 * r * r;
          _retargetAt[i] =
              elapsed +
              Duration(milliseconds: 120 + (_rand.nextDouble() * 380).round());
        }
        final v = _value[i];
        final t = _target[i];
        _value[i] = v + (t - v) * (t > v ? 0.5 : 0.12);
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Fixed frame: bar heights dance inside it, the widget's own
    // box never moves — no bounce in the surrounding row.
    return SizedBox(
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _bars; i++)
            Container(
              width: 3,
              height: 4 + 12 * _value[i].clamp(0.0, 1.0),
              margin: EdgeInsets.only(right: i == _bars - 1 ? 0 : 2),
              decoration: BoxDecoration(
                color: archPink,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}
