import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../changelog_store.dart';

/// One changelog row: author face, message, short hash + name + date.
/// Shared by the What's New page and the update dialog so the two can
/// never disagree about what a commit looks like.
class CommitRow extends StatelessWidget {
  final ChangelogEntry entry;

  const CommitRow({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = entry.author.isEmpty
        ? '?'
        : entry.author.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 36,
              height: 36,
              child: entry.author.isEmpty
                  ? _FallbackFace(initial: initial)
                  : CachedNetworkImage(
                      imageUrl: entry.avatarUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          _FallbackFace(initial: initial),
                      errorWidget: (_, _, _) =>
                          _FallbackFace(initial: initial),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.message,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.short} · ${entry.author} · ${entry.date}',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackFace extends StatelessWidget {
  final String initial;

  const _FallbackFace({required this.initial});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
