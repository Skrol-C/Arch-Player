import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import 'data/library_repository.dart';

String fmtDuration(Duration d) {  if (d.inMilliseconds <= 0) return '--:--';
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
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
      leading: SizedBox(width: 52, height: 52, child: art),
      title: Text(song.title,
          maxLines: 1, style: TextStyle(color: isCurrent ? archRed : Colors.white)),
      subtitle: Text(song.artist, maxLines: 1, style: const TextStyle(color: inkTextDim)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent) const NowBars(),
          const SizedBox(width: 8),
          Text(fmtDuration(song.duration), style: const TextStyle(color: inkTextDim)),
        ],
      ),
    );
  }
}

/// Album art over our own channel, memory-cached. Falls back to a disc.
class AlbumArt extends StatelessWidget {
  final int albumId;
  final double size;
  final double radius;
  final bool fill;

  const AlbumArt(
      {super.key, required this.albumId, this.size = 52, this.radius = 10, this.fill = false});

  @override
  Widget build(BuildContext context) {
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: inkRaised),
          FutureBuilder(
            future: ArtCache.of(albumId),
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes != null && bytes.isNotEmpty) {
                return Image.memory(bytes,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const _DiscIcon());
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
    return Container(
      color: inkRaised,
      child: const Icon(Icons.music_note, color: inkTextDim),
    );
  }
}
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
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
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
              decoration: BoxDecoration(color: archRed, borderRadius: BorderRadius.circular(2)),
            ),
        ],
      ),
    );
  }
}
