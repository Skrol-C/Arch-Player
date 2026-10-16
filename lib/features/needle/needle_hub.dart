import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'catalog_store.dart';
import 'extension.dart';
import 'needle_store.dart';
import 'queue_runner.dart';
import 'queue_store.dart';
import 'session_grant.dart';
import 'verify_sheet.dart';

/// Needle hub: downloads queue + catalog. Search finds; this
/// manages. Two pills under a display header: Queue (live pulls)
/// and Catalog (landed library). Doctor arrives separately.
class NeedleHubPage extends ConsumerStatefulWidget {
  const NeedleHubPage({super.key});

  @override
  ConsumerState<NeedleHubPage> createState() => _NeedleHubPageState();
}

class _NeedleHubPageState extends ConsumerState<NeedleHubPage> {
  bool _catalog = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                'Needle',
                style: TextStyle(
                  fontFamily: 'ArchSerif',
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Center(child: _Switcher(
              catalog: _catalog,
              onPick: (v) {
                HapticFeedback.selectionClick();
                setState(() => _catalog = v);
              },
            )),
            const SizedBox(height: 8),
            Expanded(
              child: _catalog
                  ? const _CatalogPane()
                  : const _QueuePane(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating glass switcher: one static lens, never stacked with
/// content glass (there is none) or the dock (different corner).
class _Switcher extends StatelessWidget {
  final bool catalog;
  final void Function(bool) onPick;
  const _Switcher({required this.catalog, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassLens(
      style: ArchGlass.capsule(radius: 22),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tab('Queue', !catalog, () => onPick(false)),
            _tab('Catalog', catalog, () => onPick(true)),
          ],
        ),
      ),
    );
  }

  Widget _tab(String label, bool on, VoidCallback tap) {
    return GestureDetector(
      onTap: tap,
      child: AnimatedContainer(
        duration: Motion.stateChange,
        padding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: on ? archPink : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? Colors.white : ink,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _QueuePane extends ConsumerWidget {
  const _QueuePane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(downloadQueueProvider);
    if (jobs.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: const [
          FocalEntrance(
            child: Text(
              'Nothing queued.',
              style: TextStyle(
                fontFamily: 'ArchSerif',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Pull a track from Search or a song page and it lands here with live progress.',
            style: TextStyle(color: inkDim, height: 1.5),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 48),
      itemCount: jobs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _JobRow(job: jobs[i]),
    );
  }
}

class _JobRow extends ConsumerWidget {
  final QueueJob job;
  const _JobRow({required this.job});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.read(downloadQueueProvider.notifier);
    final pct = job.progress <= 0
        ? ''
        : '  ${(job.progress * 100).round()}%';
    final phase = switch (job.phase) {
      QueuePhase.resolving => 'Finding',
      QueuePhase.downloading => 'Pulling',
      QueuePhase.decrypting => 'Unlocking',
      QueuePhase.publishing => 'Landing',
    };
    final status = switch (job.state) {
      QueueState.queued => 'Queued',
      QueueState.active => '$phase$pct',
      QueueState.paused => 'Paused',
      QueueState.done => 'Landed',
      QueueState.failed => job.error ?? 'Failed',
    };
    return Container(
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      // Own transparent Material (invisible-splash exceptions).
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: job.art.isEmpty
              ? Container(
                  width: 56,
                  height: 56,
                  color: paper,
                  child: const Icon(
                      Icons.music_note_rounded, color: inkDim),
                )
              : CachedNetworkImage(
            memCacheWidth: 112,
            memCacheHeight: 112,
            maxWidthDiskCache: 512,
            maxHeightDiskCache: 512,
                  imageUrl: job.art,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    width: 56,
                    height: 56,
                    color: paper,
                    child: const Icon(
                        Icons.music_note_rounded, color: inkDim),
                  ),
                ),
        ),
        title: Text(
          job.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontWeight: FontWeight.w700, fontSize: 16),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [job.artist, job.providerName]
                  .where((s) => s.isNotEmpty)
                  .join('  |  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: inkDim, fontSize: 13),
            ),
            const SizedBox(height: 6),
            if (job.state == QueueState.active) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: job.progress > 0 ? job.progress : null,
                  minHeight: 5,
                  backgroundColor: ink.withValues(alpha: 0.08),
                  valueColor: const AlwaysStoppedAnimation(archPink),
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              status,
              style: TextStyle(
                color: job.state == QueueState.failed
                    ? archPink
                    : inkDim,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        trailing: _trailing(context, ref, queue),
        ),
      ),
    );
  }

  Future<void> _retry(
    BuildContext context, WidgetRef ref, DownloadQueueNotifier queue) async {
    // Capture the container while the widget is certainly mounted:
    // the verification flow awaits, and this BuildContext may be
    // gone by the time the pull starts.
    final container = ProviderScope.containerOf(context, listen: false);
    const prefix = 'Needs verification: ';
    final err = job.error ?? '';
    if (err.startsWith(prefix)) {
      final rest = err.substring(prefix.length);
      final inlineUrl = rest.startsWith('auth_url=')
          ? rest.substring('auth_url='.length)
          : '';
      InstalledExtension? provider;
      for (final p in ref.read(installedExtensionsProvider)) {
        if (p.id == job.providerId) {
          provider = p;
          break;
        }
      }
      if (provider != null) {
        final url = await SessionGrant.resolveAuthUrl(
            provider.id, inlineUrl);
        if (url != null && url.isNotEmpty && context.mounted) {
          final granted = await handleVerifyRequired(
            context,
            extId: provider.id,
            displayName: provider.displayName,
            authUrl: url,
          );
          if (granted) {
            queue.retry(job.id);
            runQueue(container);
          }
          return;
        }
      }
    }
    queue.retry(job.id);
    runQueue(container);
  }

  Widget _trailing(
      BuildContext context, WidgetRef ref, DownloadQueueNotifier queue) {
    switch (job.state) {
      case QueueState.done:
        return const Padding(
          padding: EdgeInsets.only(right: 8),
          child: Icon(Icons.check_circle_rounded, color: archPink),
        );
      case QueueState.failed:
        // Verify-gated pulls complete their grant here, then retry.
        return IconButton(
          tooltip: 'Retry',
          onPressed: () => _retry(context, ref, queue),
          icon: const Icon(Icons.refresh_rounded, color: archPink),
        );
      case QueueState.active:
        return IconButton(
          tooltip: 'Cancel',
          onPressed: () => queue.cancel(job.id),
          icon: const Icon(Icons.close_rounded, color: inkDim),
        );
      case QueueState.queued:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Pause',
              onPressed: () => queue.setPaused(job.id, true),
              icon:
                  const Icon(Icons.pause_rounded, color: inkDim),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: () => queue.cancel(job.id),
              icon:
                  const Icon(Icons.close_rounded, color: inkDim),
            ),
          ],
        );
      case QueueState.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Resume',
              onPressed: () => queue.setPaused(job.id, false),
              icon:
                  const Icon(Icons.play_arrow_rounded, color: archPink),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: () => queue.cancel(job.id),
              icon:
                  const Icon(Icons.close_rounded, color: inkDim),
            ),
          ],
        );
    }
  }
}

class _CatalogPane extends ConsumerWidget {
  const _CatalogPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(catalogProvider);
    if (entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: const [
          FocalEntrance(
            child: Text(
              'Nothing filed yet.',
              style: TextStyle(
                fontFamily: 'ArchSerif',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Every pull files here with its date, provider, and quality — albums and tracks, playlists later.',
            style: TextStyle(color: inkDim, height: 1.5),
          ),
        ],
      );
    }
    final albums = <String, List<CatalogEntry>>{};
    final singles = <CatalogEntry>[];
    for (final e in entries) {
      // Release type decides, not the album tag: a single carries an
      // album name but was filed (and should read) as a track.
      if (e.isAlbum) {
        albums.putIfAbsent(e.album, () => []).add(e);
      } else {
        singles.add(e);
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 48),
      children: [
        if (albums.isNotEmpty) ...[
          const _GroupHeader(label: 'Albums'),
          for (final name in albums.keys)
            _AlbumCard(name: name, tracks: albums[name]!),
        ],
        if (singles.isNotEmpty) ...[
          const _GroupHeader(label: 'Tracks'),
          for (final e in singles) ...[
            _EntryRow(entry: e),
            const SizedBox(height: 6),
          ],
        ],
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'ArchSerif',
          fontSize: 24,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final String name;
  final List<CatalogEntry> tracks;
  const _AlbumCard({required this.name, required this.tracks});

  @override
  Widget build(BuildContext context) {
    final first = tracks.first;
    final date = DateTime.fromMillisecondsSinceEpoch(first.landedMs);
    final when =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return Container(
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Own transparent Material (invisible-splash exceptions).
          Material(
            type: MaterialType.transparency,
            child: ListTile(
            contentPadding:
                const EdgeInsets.fromLTRB(10, 6, 16, 6),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: first.art.isEmpty
                  ? Container(
                      width: 56,
                      height: 56,
                      color: paper,
                      child: const Icon(Icons.album_outlined,
                          color: inkDim),
                    )
                  : CachedNetworkImage(
            memCacheWidth: 112,
            memCacheHeight: 112,
            maxWidthDiskCache: 512,
            maxHeightDiskCache: 512,
                      imageUrl: first.art,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(
                        width: 56,
                        height: 56,
                        color: paper,
                        child: const Icon(Icons.album_outlined,
                            color: inkDim),
                      ),
                    ),
            ),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 16),
            ),
            subtitle: Text(
              '${first.artist}  |  ${tracks.length} tracks  |  $when',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: inkDim, fontSize: 13),
            ),
          ),
        ),
        ],
      ),
    );
  }
}
class _EntryRow extends StatelessWidget {
  final CatalogEntry entry;
  const _EntryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final date =
        DateTime.fromMillisecondsSinceEpoch(entry.landedMs);
    final when =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final quality = NeedleQualitiesLabel.of(entry.quality);
    return Container(
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      // Own transparent Material (invisible-splash exceptions).
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: entry.art.isEmpty
              ? Container(
                  width: 56,
                  height: 56,
                  color: paper,
                  child: const Icon(Icons.music_note_rounded,
                      color: inkDim),
                )
              : CachedNetworkImage(
            memCacheWidth: 112,
            memCacheHeight: 112,
            maxWidthDiskCache: 512,
            maxHeightDiskCache: 512,
                  imageUrl: entry.art,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    width: 56,
                    height: 56,
                    color: paper,
                    child: const Icon(Icons.music_note_rounded,
                        color: inkDim),
                  ),
                ),
        ),
        title: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontWeight: FontWeight.w700, fontSize: 16),
        ),
        subtitle: Text(
          [entry.artist, entry.provider, quality, when]
              .where((String s) => s.isNotEmpty)
              .join('  |  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: inkDim, fontSize: 13),
        ),
      ),
        ),
    );
  }
}