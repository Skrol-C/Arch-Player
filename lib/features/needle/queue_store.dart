import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/log.dart';
import 'extension.dart';
import 'needle_store.dart';

/// Download queue: every pull enqueues here instead of firing
/// ad-hoc. Extension pulls are phase-based (availability ->
/// download -> decrypt -> publish) with no byte stream, so
/// progress is phase-mapped and honest about it: determinate
/// only where measured, indeterminate inside extension calls.
///
/// States: queued -> active -> done | failed (+ paused holds a
/// queued job; cancel is cooperative between phases). Failures
/// fall through the ordered provider list (smart router) before
/// surfacing.
enum QueueState { queued, active, paused, done, failed }

enum QueuePhase { resolving, downloading, decrypting, publishing }

class QueueJob {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String art;
  final String isrc;
  final List<({String id, String name})> providers;
  final int attempt;
  final String quality;
  final QueueState state;
  final QueuePhase phase;
  final double progress;
  final String? error;

  const QueueJob({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.art = '',
    this.isrc = '',
    required this.providers,
    this.attempt = 0,
    required this.quality,
    this.state = QueueState.queued,
    this.phase = QueuePhase.resolving,
    this.progress = 0,
    this.error,
  });

  String get providerId =>
      attempt < providers.length ? providers[attempt].id : '';
  String get providerName =>
      attempt < providers.length ? providers[attempt].name : '';

  QueueJob copyWith({
    int? attempt,
    QueueState? state,
    QueuePhase? phase,
    double? progress,
    String? error,
  }) =>
      QueueJob(
        id: id,
        title: title,
        artist: artist,
        album: album,
        art: art,
        isrc: isrc,
        providers: providers,
        attempt: attempt ?? this.attempt,
        quality: quality,
        state: state ?? this.state,
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        error: error,
      );
}

final downloadQueueProvider =
    NotifierProvider<DownloadQueueNotifier, List<QueueJob>>(
        DownloadQueueNotifier.new);

/// Glow: set when a pull lands; cleared when the hub is opened.
/// The pill badge counts pending jobs; glow marks fresh landings.
final needleGlowProvider = StateProvider<bool>((ref) => false);

class DownloadQueueNotifier extends Notifier<List<QueueJob>> {
  static int _seq = 0;

  @override
  List<QueueJob> build() => const [];

  /// Enqueue a pull. Returns the job id. The runner (wired next)
  /// picks it up; until then it waits honestly as queued.
  String enqueue({
    required String title,
    required String artist,
    String album = '',
    String art = '',
    String isrc = '',
    required List<InstalledExtension> providers,
    String? providerId,
    String? quality,
  }) {
    final ordered = [
      for (final p in providers)
        if (p.enabled && p.roles.contains('download')) p,
    ]..sort((a, b) => a.priority.compareTo(b.priority));
    if (providerId != null && providerId.isNotEmpty) {
      ordered.sort((a, b) {
        if (a.id == providerId) return -1;
        if (b.id == providerId) return 1;
        return 0;
      });
    }
    final id = 'q${DateTime.now().millisecondsSinceEpoch}-${_seq++}';
    final job = QueueJob(
      id: id,
      title: title,
      artist: artist,
      album: album,
      art: art,
      isrc: isrc,
      providers: [
        for (final p in ordered) (id: p.id, name: p.displayName),
      ],
      quality: quality ?? NeedlePrefs.qualityLossless,
    );
    state = [...state, job];
    ArchLog.i('queue', 'enqueued $title ($id, ${job.providers.length} providers)');
    return id;
  }

  void update(String id,
      {QueueState? state,
      QueuePhase? phase,
      double? progress,
      String? error,
      int? attempt,
      bool clearError = false}) {
    this.state = [
      for (final j in this.state)
        if (j.id == id)
          j.copyWith(
            state: state,
            phase: phase,
            progress: progress,
            error: clearError ? null : (error ?? j.error),
            attempt: attempt,
          )
        else
          j,
    ];
  }

  /// Pause holds a queued job; an active extension call cannot be
  /// paused mid-flight, so it finishes its phase then holds.
  void setPaused(String id, bool paused) {
    for (final j in state) {
      if (j.id != id) continue;
      if (j.state == QueueState.queued && paused) {
        update(id, state: QueueState.paused);
      } else if (j.state == QueueState.paused && !paused) {
        update(id, state: QueueState.queued);
      }
    }
  }

  void cancel(String id) {
    state = state.where((j) => j.id != id).toList();
    ArchLog.i('queue', 'cancelled $id');
  }

  void retry(String id) {
    update(id,
        state: QueueState.queued,
        phase: QueuePhase.resolving,
        progress: 0,
        attempt: 0,
        clearError: true);
  }

  void clearDone() {
    state = state
        .where((j) =>
            j.state != QueueState.done && j.state != QueueState.failed)
        .toList();
  }

  int get activeCount =>
      state.where((j) => j.state == QueueState.active).length;
  int get pendingCount => state
      .where((j) =>
          j.state == QueueState.queued || j.state == QueueState.active)
      .length;
}
