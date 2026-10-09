import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'song_row.dart';

/// One discography category, full grid. Owned in color + pink ring,
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
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 24,
          childAspectRatio: 0.78,
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
                Expanded(child: ReleaseCover(release: r, owned: owned, fill: true)),
                const SizedBox(height: 6),
                Text(r.title,
                    maxLines: 1,
                    style: TextStyle(
                        color: owned ? ink : inkDim, fontWeight: FontWeight.w600)),
                if (r.year != null)
                  Text('${r.year}', style: const TextStyle(color: inkDim, fontSize: 12)),
              ],
            ),
          );
        },
      ),
    );
  }
}
