import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';

/// One discography category, full grid. Owned in color + red ring,
/// missing grayed (tap routes to Needle later — never a dead end).
class ReleaseGallery extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('$artistName — $label')),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          childAspectRatio: 0.8,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final r = items[i];
          final owned = ownedTitles.contains(r.title.toLowerCase());
          return FocalEntrance(
            index: i,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: inkRaised,
                      borderRadius: BorderRadius.circular(16),
                      border: owned ? Border.all(color: archRed, width: 2) : null,
                    ),
                    foregroundDecoration: owned
                        ? null
                        : const BoxDecoration(
                            color: Color(0x99000000),
                            borderRadius: BorderRadius.all(Radius.circular(16)),
                          ),
                    child: Center(
                      child: r.artUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(16),
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
                                  memCacheWidth: 500,
                                  errorWidget: (_, _, _) =>
                                      const Icon(Icons.album, color: Colors.white, size: 48),
                                ),
                              ),
                            )
                          : const Icon(Icons.album, color: inkTextDim, size: 48),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(r.title,
                    maxLines: 1,
                    style: TextStyle(color: owned ? Colors.white : inkTextDim)),
                if (r.year != null)
                  Text('${r.year}',
                      style: const TextStyle(color: inkTextDim, fontSize: 12)),
              ],
            ),
          );
        },
      ),
    );
  }
}
