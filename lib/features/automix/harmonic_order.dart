// Harmonic ordering: which tracks blend into which. Pure, no player,
// no I/O — the handler owns transport, the UI owns display, both ask
// here. A track with no BPM *and* no key can't be compared, so it's
// never picked (it still plays in plain/shuffle modes).
//
// Scoring mirrors the crossfade brain's ears: Camelot proximity first,
// tempo gap second. Unknowns score nothing and are filtered before
// ranking, never guessed.

import 'dart:math' as math;

import '../../core/models.dart';

/// Camelot relation between two Traktor open keys ('5m', '8d').
enum HarmonicRel { same, relative, adjacent, energy, far, unknown }

({int number, bool minor})? _parseOpen(String? open) {
  if (open == null) return null;
  final m =
      RegExp(r'^(\d{1,2})\s*([md])$', caseSensitive: false)
          .firstMatch(open.trim());
  if (m == null) return null;
  final num = int.tryParse(m.group(1)!);
  if (num == null || num < 1 || num > 12) return null;
  return (number: num, minor: m.group(2)!.toLowerCase() == 'm');
}

int _wheelDistance(int a, int b) {
  final raw = (a - b).abs() % 12;
  return raw > 6 ? 12 - raw : raw;
}

HarmonicRel harmonicRelation(String? a, String? b) {
  final pa = _parseOpen(a);
  final pb = _parseOpen(b);
  if (pa == null || pb == null) return HarmonicRel.unknown;
  if (pa.number == pb.number && pa.minor == pb.minor) return HarmonicRel.same;
  if (pa.number == pb.number) return HarmonicRel.relative;
  final d = _wheelDistance(pa.number, pb.number);
  if (d == 1) return HarmonicRel.adjacent;
  if (d == 2) return HarmonicRel.energy;
  return HarmonicRel.far;
}

/// Octave-tolerant tempo gap, mirroring the crossfade brain: half and
/// double count as the same groove.
double? tempoGap(double? a, double? b) {
  if (a == null || b == null || a <= 0 || b <= 0) return null;
  var best = (a - b).abs() / math.max(a, b);
  for (final mult in [2.0, 0.5]) {
    final alt = (a * mult - b).abs() / math.max(a * mult, b);
    if (alt < best) best = alt;
  }
  return best;
}

/// Compatibility of [b] following [a]: higher blends better. Unknowns
/// (either side) score lowest and are filtered before ranking.
double harmonicScore({
  required String? openA,
  required String? openB,
  required double? bpmA,
  required double? bpmB,
}) {
  final base = switch (harmonicRelation(openA, openB)) {
    HarmonicRel.same => 100.0,
    HarmonicRel.relative => 85.0,
    HarmonicRel.adjacent => 70.0,
    HarmonicRel.energy => 50.0,
    HarmonicRel.far => 20.0,
    HarmonicRel.unknown => 0.0,
  };
  final gap = tempoGap(bpmA, bpmB);
  if (gap == null) return base * 0.5;
  return (base - math.min(40.0, gap * 400.0)).clamp(0.0, 100.0);
}

/// Greedy harmonic walk: from [fromId], repeatedly take the best-
/// compatible unplayed track, [k] deep. Unknown tracks (no BPM and no
/// key) are never picked; recently played ids are avoided until the
/// pool runs dry, then anything goes rather than stopping the music.
/// Deterministic: ties break by lower id.
List<int> pickHarmonicBatch({
  required List<Song> songs,
  required TrackMusicalInfo? Function(Song song) infoOf,
  required int fromId,
  required Set<int> recentIds,
  required int k,
}) {
  if (songs.length < 2 || k <= 0) return const [];
  final byId = {for (final s in songs) s.id: s};
  if (!byId.containsKey(fromId)) return const [];
  double scoreOf(Song a, Song b) {
    final ia = infoOf(a);
    final ib = infoOf(b);
    if (ia == null || ib == null || ia.isEmpty || ib.isEmpty) return -1;
    return harmonicScore(
      openA: ia.openKey.isEmpty ? null : ia.openKey,
      openB: ib.openKey.isEmpty ? null : ib.openKey,
      bpmA: ia.bpm,
      bpmB: ib.bpm,
    );
  }

  final picked = <int>[];
  final banned = Set<int>.of(recentIds)..add(fromId);
  var cur = fromId;
  for (var n = 0; n < k; n++) {
    Song? best;
    var bestScore = double.negativeInfinity;
    for (final s in songs) {
      if (s.id == cur || picked.contains(s.id)) continue;
      if (banned.contains(s.id)) continue;
      final sc = scoreOf(byId[cur]!, s);
      if (sc < 0) continue;
      if (sc > bestScore ||
          (sc == bestScore && best != null && s.id < best.id)) {
        bestScore = sc;
        best = s;
      }
    }
    // Pool exhausted (everything recent or unknown): relax the ban,
    // keep the music moving. Unknowns still never qualify.
    best ??= _bestIgnoringBan(songs, byId, cur, picked, scoreOf);
    if (best == null) break;
    picked.add(best.id);
    cur = best.id;
  }
  return picked;
}

/// Best-compatible track ignoring the recent-ban (unknowns still out).
Song? _bestIgnoringBan(
  List<Song> songs,
  Map<int, Song> byId,
  int cur,
  List<int> picked,
  double Function(Song a, Song b) scoreOf,
) {
  Song? best;
  var bestScore = double.negativeInfinity;
  for (final s in songs) {
    if (s.id == cur || picked.contains(s.id)) continue;
    final sc = scoreOf(byId[cur]!, s);
    if (sc < 0) continue;
    if (sc > bestScore ||
        (sc == bestScore && best != null && s.id < best.id)) {
      bestScore = sc;
      best = s;
    }
  }
  return best;
}
