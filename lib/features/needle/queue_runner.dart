import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../library/library_providers.dart';
import 'catalog_store.dart';
import 'extension.dart';
import 'needle_store.dart';
import 'pull.dart';
import 'queue_store.dart';
import 'sandbox.dart';

/// Queue runner: executes queued jobs sequentially through
/// pullTrack with phase progress. Failures fall through the
/// job's ordered providers (smart router) before surfacing.
/// One runner at a time; enqueue/retry/unpause kick it.
///
/// Takes a [ProviderContainer], never a WidgetRef: the pull
/// awaits for many seconds, and touching a widget-owned ref
/// after an await throws once that widget is gone (the runner
/// outlives the sheet/hub that started it). The container
/// lives as long as the app scope, so it is always safe.
///
/// Honest limits: an in-flight extension call cannot be aborted
/// (cancel of an active job removes the row; the phase finishes
/// and the track still lands). Verify-gated pulls fail with the
/// auth URL in the error; the user completes verification from
/// search, then retries.
bool _running = false;

Future<void> runQueue(ProviderContainer container) async {
  if (_running) return;
  _running = true;
  try {
    await _drain(container);
  } finally {
    _running = false;
  }
}

Future<void> _drain(ProviderContainer container) async {
  final queue = container.read(downloadQueueProvider.notifier);
  while (true) {
    final jobs = container.read(downloadQueueProvider);
    QueueJob? next;
    for (final j in jobs) {
      if (j.state == QueueState.queued) {
        next = j;
        break;
      }
    }
    if (next == null) return;
    await _runJob(container, queue, next);
  }
}

Future<void> _runJob(
  ProviderContainer container,
  DownloadQueueNotifier queue,
  QueueJob job,
) async {
  // Job may have been cancelled while waiting.
  if (!container.read(downloadQueueProvider).any((j) => j.id == job.id)) {
    return;
  }
  final installed = container.read(installedExtensionsProvider);
  InstalledExtension? providerFor(String id) {
    for (final p in installed) {
      if (p.id == id) return p;
    }
    return null;
  }

  var attempt = job.attempt;
  while (true) {
    if (!container.read(downloadQueueProvider).any((j) => j.id == job.id)) {
      return;
    }
    final providers = container
        .read(downloadQueueProvider)
        .firstWhere((j) => j.id == job.id)
        .providers;
    if (attempt >= providers.length) {
      queue.update(job.id,
          state: QueueState.failed,
          error: 'No provider could pull it',
          progress: 0);
      return;
    }
    final meta = providers[attempt];
    final provider = providerFor(meta.id);
    if (provider == null || !provider.enabled) {
      attempt++;
      queue.update(job.id, attempt: attempt);
      continue;
    }
    queue.update(job.id,
        state: QueueState.active,
        attempt: attempt,
        phase: QueuePhase.resolving,
        progress: 0.05,
        clearError: true);
    String landedPath = '';
    String landedFormat = '';
    try {
      final pulled = await pullTrack(
        provider: provider,
        title: job.title,
        artist: job.artist,
        isrc: job.isrc,
        quality: job.quality,
        album: job.album.isEmpty ? null : job.album,
        artUrl: job.art,
        releaseType: job.releaseType,
        onPhase: (phase, progress) {
          queue.update(job.id, phase: phase, progress: progress);
        },
      );
      landedPath = pulled.path;
      landedFormat = pulled.format;
      if (!container.read(downloadQueueProvider).any((j) => j.id == job.id)) {
        // Cancelled mid-flight: row gone, track still landed.
        container.invalidate(songsProvider);
        return;
      }
      queue.update(job.id,
          state: QueueState.done, phase: QueuePhase.publishing, progress: 1);
      ArchLog.i('queue', 'landed ${job.title} via ${provider.id}');
      final catalog = container.read(catalogProvider.notifier);
      // Re-pull replaces: one entry per recording. The earlier file
      // itself survives for now — Dart has no write access under
      // scoped storage — but the catalog stops piling up numbered
      // duplicates, and this is the single place native delete
      // plugs in later.
      final prior = catalog.priorFor(job.title, job.artist);
      if (prior.isNotEmpty) {
        await catalog.removeIds({for (final p in prior) p.id});
        ArchLog.i('queue', 'replaced ${prior.length} earlier ${job.title}');
      }
      await catalog.record(CatalogEntry(
            id: 'c${DateTime.now().millisecondsSinceEpoch}',
            title: job.title,
            artist: job.artist,
            album: job.album,
            art: job.art,
            provider: provider.displayName,
            quality: job.quality,
            landedMs: DateTime.now().millisecondsSinceEpoch,
            path: landedPath,
            format: landedFormat,
            releaseType: job.releaseType,
          ));
      container.read(needleGlowProvider.notifier).state = true;
      await Future<void>.delayed(const Duration(seconds: 2));
      container.invalidate(songsProvider);
      return;
    } on NeedleException catch (e) {
      if (e.code == 'verify-required') {
        queue.update(job.id,
            state: QueueState.failed,
            error: 'Needs verification: ${e.message}',
            progress: 0);
        ArchLog.w('queue', 'verify required for ${job.title}');
        return;
      }
      attempt++;
      ArchLog.w('queue',
          'attempt $attempt/${providers.length} failed for ${job.title}: ${e.code}');
      if (attempt >= providers.length) {
        queue.update(job.id,
            state: QueueState.failed,
            error: switch (e.code) {
              'unavailable' => 'Not available from ${meta.name}',
              _ => 'Pull failed: ${e.code}',
            },
            progress: 0);
        return;
      }
      queue.update(job.id, attempt: attempt);
    }
  }
}
