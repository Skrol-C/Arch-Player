import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import 'extension.dart';
import 'needle_store.dart';
import 'queue_runner.dart';
import 'queue_store.dart';
import 'session_grant.dart';
import 'verify_sheet.dart';

/// Needle hub: downloads queue. Catalog moved to the library index.
/// Search finds; this manages.
class NeedleHubPage extends ConsumerWidget {
  const NeedleHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
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
            SizedBox(height: 8),
            Expanded(
              child: _QueuePane(),
            ),
          ],
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
        children: [
          const FocalEntrance(
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
          const SizedBox(height: 8),
          Text(
            'Pull a track from Search or a song page and it lands here with live progress.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5),
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                  color: Theme.of(context).colorScheme.surface,
                  child: Icon(
                      Icons.music_note_rounded,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant),
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
                  errorWidget: (ctx, _, _) => Container(
                    width: 56,
                    height: 56,
                    color: Theme.of(ctx).colorScheme.surface,
                    child: Icon(
                        Icons.music_note_rounded,
                        color: Theme.of(ctx)
                            .colorScheme
                            .onSurfaceVariant),
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
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13),
            ),
            const SizedBox(height: 6),
            if (job.state == QueueState.active) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: job.progress > 0 ? job.progress : null,
                  minHeight: 5,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.08),
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
                    : Theme.of(context).colorScheme.onSurfaceVariant,
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
          icon: Icon(Icons.close_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        );
      case QueueState.queued:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Pause',
              onPressed: () => queue.setPaused(job.id, true),
              icon: Icon(Icons.pause_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: () => queue.cancel(job.id),
              icon: Icon(Icons.close_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
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
              icon: const Icon(Icons.play_arrow_rounded, color: archPink),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: () => queue.cancel(job.id),
              icon: Icon(Icons.close_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        );
    }
  }
}
