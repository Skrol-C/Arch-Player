import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../metadata/metadata_providers.dart';
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

  const AlbumArt(
      {super.key,
      required this.albumId,
      this.size = 52,
      this.radius = 12,
      this.fill = false,
      this.detail = false});

  @override
  Widget build(BuildContext context) {
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: paperRaised),
          FutureBuilder(
            future: ArtCache.of(
                albumId, detail ? ArtBucket.large : ArtBucket.small),
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes != null && bytes.isNotEmpty) {
                return Image.memory(bytes,
                    fit: BoxFit.cover, errorBuilder: (_, _, _) => const _DiscIcon());
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

class _DiscIcon extends StatelessWidget {
  const _DiscIcon();

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.music_note, color: inkDim);
  }
}

/// One release cover: known art URL first, else CAA resolve by MBID,
/// else the designed monogram fallback. Owned = color + pink ring.
class ReleaseCover extends StatelessWidget {
  final ReleaseGroup release;
  final bool owned;
  final double size;
  final bool fill;

  const ReleaseCover(
      {super.key, required this.release, required this.owned, this.size = 118, this.fill = false});

  @override
  Widget build(BuildContext context) {
    final direct = release.artUrl;
    final mbid = release.rgMbid;
    final Widget body = (direct != null)
        ? _art(direct)
        : (mbid != null ? _CaaCover(mbid: mbid) : _fallback());
    final framed = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: owned ? Border.all(color: archPink, width: 2) : null,
        boxShadow: const [
          BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColorFiltered(
          colorFilter: owned
              ? const ColorFilter.mode(Colors.transparent, BlendMode.multiply)
              : const ColorFilter.matrix(<double>[
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0, 0, 0, 0.55, 0,
                ]),
          child: body,
        ),
      ),
    );
    if (fill) return SizedBox.expand(child: framed);
    return SizedBox(width: size, height: size, child: framed);
  }

  Widget _art(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: 300,
      errorWidget: (_, _, _) => _fallback(),
    );
  }

  Widget _fallback() {
    return Container(
      color: paperRaised,
      child: Center(
        child: Text(
          release.title.isEmpty ? '?' : release.title[0].toUpperCase(),
          style: const TextStyle(color: archPink, fontSize: 40, fontWeight: FontWeight.w700),
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
        color: paperRaised,
        child: const Center(child: Icon(Icons.album, color: inkDim, size: 40)),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: 300,
      errorWidget: (_, _, _) => Container(
        color: paperRaised,
        child: const Center(child: Icon(Icons.album, color: inkDim, size: 40)),
      ),
    );
  }
}

class SongRow extends StatelessWidget {
  final Song song;
  final Widget art;
  final bool isCurrent;
  final VoidCallback onTap;

  const SongRow({super.key, required this.song, required this.art, required this.isCurrent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: SizedBox(width: 52, height: 52, child: art),
      title: Text(song.title,
          maxLines: 1, style: TextStyle(color: isCurrent ? archPink : ink)),
      subtitle: Text(song.artist, maxLines: 1, style: const TextStyle(color: inkDim)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent) const NowBars(),
          const SizedBox(width: 8),
          Text(fmtDuration(song.duration), style: const TextStyle(color: inkDim)),
        ],
      ),
    );
  }
}

/// Mini playing indicator. Zero-motion = bug, even here.
class NowBars extends StatefulWidget {
  const NowBars({super.key});

  @override
  State<NowBars> createState() => _NowBarsState();
}

class _NowBarsState extends State<NowBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 3,
              height: 4 + 12 * (((_c.value + i * 0.33) % 1.0)),
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(color: archPink, borderRadius: BorderRadius.circular(2)),
            ),
        ],
      ),
    );
  }
}
