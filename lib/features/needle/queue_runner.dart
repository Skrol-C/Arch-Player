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
/// Honest limits: an in-flight extension call cannot be aborted
/// (cancel of an active job removes the row; the phase finishes
/// and the track still lands). Verify-gated pulls fail with the
/// auth URL in the error; the user completes verification from
/// search, then retries.
bool _running = false;

Future<void> runQueue(WidgetRef ref) async {
  if (_running) return;
  _running = true;
  try {
    await _drain(ref);
  } finally {
    _running = false;
  }
}

Future<void> _drain(WidgetRef ref) async {
  final queue = ref.read(downloadQueueProvider.notifier);
  while (true) {
    final jobs = ref.read(downloadQueueProvider);
    QueueJob? next;
    for (final j in jobs) {
      if (j.state == QueueState.queued) {
        next = j;
        break;
      }
    }
    if (next == null) return;
    await _runJob(ref, queue, next);
  }
}

Future<void> _runJob(
  WidgetRef ref,
  DownloadQueueNotifier queue,
  QueueJob job,
) async {
  // Job may have been cancelled while waiting.
  if (!ref.read(downloadQueueProvider).any((j) => j.id == job.id)) {
    return;
  }
  final installed = ref.read(installedExtensionsProvider);
  InstalledExtension? providerFor(String id) {
    for (final p in installed) {
      if (p.id == id) return p;
    }
    return null;
  }

  var attempt = job.attempt;
  while (true) {
    if (!ref.read(downloadQueueProvider).any((j) => j.id == job.id)) {
      return;
    }
    final providers = ref
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
        onPhase: (phase, progress) {
          queue.update(job.id, phase: phase, progress: progress);
        },
      );
      landedPath = pulled.path;
      landedFormat = pulled.format;
      if (!ref.read(downloadQueueProvider).any((j) => j.id == job.id)) {
        // Cancelled mid-flight: row gone, track still landed.
        ref.invalidate(songsProvider);
        return;
      }
      queue.update(job.id,
          state: QueueState.done, phase: QueuePhase.publishing, progress: 1);
      ArchLog.i('queue', 'landed ${job.title} via ${provider.id}');
      await ref.read(catalogProvider.notifier).record(CatalogEntry(
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
          ));
      ref.read(needleGlowProvider.notifier).state = true;
      await Future<void>.delayed(const Duration(seconds: 2));
      ref.invalidate(songsProvider);
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
