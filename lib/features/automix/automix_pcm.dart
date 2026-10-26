import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'beat_grid.dart';
import 'musical_key.dart';
import '../../core/log.dart';

/// Decode to mono 16-bit 11,025 Hz PCM. Clipped mode caps at 25s
/// (the beat grid's native window); full mode decodes up to 10
/// minutes for multi-window analysis and whole-track key.
/// Null when the file can't be decoded. Scratch lives in cache,
/// deleted right after analysis.
Future<Uint8List?> decodeMono11k(String path, {bool full = false}) async {
  try {
    if (path.isEmpty || !await File(path).exists()) return null;
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/automix_${path.hashCode}.pcm';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-v',
      'error',
      '-i',
      path,
      '-ac',
      '1',
      '-ar',
      '11025',
      '-f',
      's16le',
      '-t',
      full ? '600' : '25',
      out,
    ]).timeout(const Duration(seconds: 90));
    final code = await session.getReturnCode();
    try {
      if (!ReturnCode.isSuccess(code)) return null;
      final bytes = await File(out).readAsBytes();
      if (bytes.isEmpty) return null;
      return bytes;
    } finally {
      try {
        await File(out).delete();
      } catch (_) {}
    }
  } catch (_) {
    return null;
  }
}

/// Beat grid in an isolate; the engine thread never feels it.
Future<AutoMixBeatGrid> analyzeGrid(Uint8List bytes) =>
    compute(_analyzeGrid, bytes);

AutoMixBeatGrid _analyzeGrid(Uint8List bytes) => analyzeAutomixPcm(bytes);

/// Musical key in an isolate. Verdict plus miss evidence — silence
/// returns null key with zeroed stats.
Future<({DetectedKey? key, double bestR, double margin, String best, String runner})>
analyzeKey(Uint8List bytes) => compute(_analyzeKey, bytes);

({
  DetectedKey? key,
  double bestR,
  double margin,
  String best,
  String runner,
})
_analyzeKey(Uint8List bytes) => detectMusicalKey(bytes);

/// Multi-window tempo: three 25s slices (start / 40% / 70%) analyzed
/// in parallel isolates, octave-folded onto the median with consensus
/// required — a lone window locked on half/double time no longer decides
/// alone. A halved minority (majority-half lock) gets a low-band
/// tie-break: the faster octave wins only when the kicks carry it.
/// Phase and first-sound map back to track time by adding the
/// winning window's offset. Short tracks (< ~27s) keep the single
/// start window. Returns the consensus, its window, and the window
/// count for logging — the caller still applies the confidence gate.
Future<({AutoMixBeatGrid grid, int window, int of})> analyzeTempoWindows(
  Uint8List pcm,
) async {
  const windowBytes = 11025 * 2 * 25;
  const fractions = [0.0, 0.4, 0.7];
  final totalSec = pcm.length / (11025 * 2);
  final starts = totalSec < 27
      ? [0]
      : [
          for (final f in fractions)
            ((totalSec - 25.0) * f * 11025 * 2).round(),
        ];
  final slices = <Uint8List>[];
  for (final start in starts) {
    final end = (start + windowBytes).clamp(0, pcm.length);
    slices.add(
      Uint8List.sublistView(pcm, start, end),
    );
  }
  final grids = await Future.wait(slices.map(analyzeGrid));
  final consensus = consensusTempo(grids);
  final best = consensus.winner;
  final offsetSec = starts[best] / (11025 * 2);
  final won = grids[best];
  var bpm = consensus.bpm;
  // Octave tie-break: a halved minority heard the faster octave. Take
  // it only when the kick band carries it — four-on-the-floor counted
  // at half time flips up; genuine half-time feels hold. Majority-half
  // is the one case median folding can't survive, and this is it.
  if (consensus.agreed && consensus.halved.isNotEmpty) {
    final trackPhase = won.phase + offsetSec;
    final covSlow = lowBandCoverage(pcm, consensus.bpm, trackPhase);
    final covFast = lowBandCoverage(pcm, consensus.bpm * 2.0, trackPhase);
    if (preferDouble(covSlow, covFast)) {
      bpm = consensus.bpm * 2.0;
      ArchLog.i(
        'automix',
        'tempo octave up ${consensus.bpm.toStringAsFixed(2)} -> '
        '${bpm.toStringAsFixed(2)} '
        'slow=${covSlow.toStringAsFixed(2)} '
        'fast=${covFast.toStringAsFixed(2)}',
      );
    }
  }
  // One line per analysis: proves the folding code is live on-device
  // and shows exactly what it did (raw -> folded -> verdict).
  ArchLog.i(
    'automix',
    'tempo consensus raw=${grids.map((g) => g.bpm.toStringAsFixed(1)).join(',')} '
    'folded=${consensus.folded.map((b) => b.toStringAsFixed(1)).join(',')} '
    'bpm=${bpm.toStringAsFixed(2)} agree=${consensus.agreed} '
    'win=${best + 1}/${slices.length}',
  );
  return (
    grid: AutoMixBeatGrid(
      bpm: bpm,
      phase: won.phase + offsetSec,
      confidence: consensus.confidence,
      firstSound: won.firstSound + offsetSec,
    ),
    window: best,
    of: slices.length,
  );
}

/// Octave folding + consensus across per-window tempo grids.
///
/// Each window detects independently, and any single window can lock onto
/// half, double, or a 4/3 harmonic of the true tempo (strong sub-beat
/// energy, syncopation). Fold every reading onto the median, then require
/// agreement — the DAD Mod Manager shape, minus librosa.
///
/// Bands (ratio = median / bpm):
/// - 1.75–2.25 → half-time read, double it.
/// - 0.45–0.57 → double-time read, halve it.
/// - 0.65–0.85 → 4/3 read, scale by 3/4.
/// - 1.20–1.45 → 3/4 read, scale by 4/3.
///
/// Returns the consensus bpm, an agreement-shaped confidence, the
/// winning window index (which supplies phase/first-sound), whether the
/// windows agreed, the folded per-window readings (for logging), and the
/// raw readings that were folded DOWN by half ([halved]) — the octave
/// tie-break candidates. No agreement (std dev > 4 BPM across folded
/// readings, or fewer than two valid windows) falls back to
/// best-confidence-wins — the caller still applies the 0.55 publish
/// gate either way.
({
  double bpm,
  double confidence,
  int winner,
  bool agreed,
  List<double> folded,
  List<double> halved,
}) consensusTempo(
  List<AutoMixBeatGrid> grids,
) {
  int bestWins() {
    var best = 0;
    for (var i = 1; i < grids.length; i++) {
      if (grids[i].confidence > grids[best].confidence ||
          (grids[i].confidence == grids[best].confidence && i == 1)) {
        best = i;
      }
    }
    return best;
  }

  final valid = [
    for (var i = 0; i < grids.length; i++)
      if (grids[i].bpm > 0) i,
  ];
  if (valid.length < 2) {
    final w = bestWins();
    return (
      bpm: grids[w].bpm,
      confidence: grids[w].confidence,
      winner: w,
      agreed: false,
      folded: [for (final g in grids) g.bpm],
      halved: const <double>[],
    );
  }
  final bpms = [for (final i in valid) grids[i].bpm]..sort();
  final median = bpms.length.isOdd
      ? bpms[bpms.length ~/ 2]
      : (bpms[bpms.length ~/ 2 - 1] + bpms[bpms.length ~/ 2]) / 2.0;
  final folded = <int, double>{};
  final halved = <double>[];
  for (final i in valid) {
    final b = grids[i].bpm;
    final ratio = median / b;
    final factor = ratio > 1.75 && ratio < 2.25
        ? 2.0
        : ratio > 0.45 && ratio < 0.57
            ? 0.5
            : ratio > 0.65 && ratio < 0.85
                ? 0.75
                : ratio > 1.2 && ratio < 1.45
                    ? 4.0 / 3.0
                    : 1.0;
    folded[i] = b * factor;
    // A halved window heard the faster octave: tie-break candidate.
    if (factor == 0.5) halved.add(b);
  }
  final values = folded.values.toList();
  final mean = values.reduce((a, b) => a + b) / values.length;
  final variance =
      values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
          values.length;
  final std = math.sqrt(variance);
  if (std > 4.0) {
    final w = bestWins();
    return (
      bpm: grids[w].bpm,
      confidence: grids[w].confidence,
      winner: w,
      agreed: false,
      // Log what folding attempted, not the raw readings — otherwise
      // the verdict line reads as if no folding ran at all.
      folded: [for (var i = 0; i < grids.length; i++) folded[i] ?? grids[i].bpm],
      halved: const <double>[],
    );
  }
  final ordered = [...values]..sort();
  final bpm = ordered.length.isOdd
      ? ordered[ordered.length ~/ 2]
      : (ordered[ordered.length ~/ 2 - 1] + ordered[ordered.length ~/ 2]) /
          2.0;
  var maxConf = 0.0;
  for (final i in valid) {
    maxConf = math.max(maxConf, grids[i].confidence);
  }
  // Agreement is evidence: independent slices landing on the same pulse
  // means the beat is really there, even when dense masters saturate the
  // onset envelope and starve the absolute scores. DAD's shape — start
  // near 0.9, dock for spread — instead of letting the weakest absolute
  // score veto a consensus. Two agreeing slices earn less than three.
  final dock = math.min(0.4, std / 20.0);
  final agreeBase = valid.length >= 3 ? 0.9 : 0.75;
  final confidence =
      math.max(maxConf - dock, agreeBase - dock).clamp(0.0, 1.0);
  // Winner supplies phase/first-sound: closest to consensus, then most
  // confident, then the middle window.
  var winner = valid.first;
  for (final i in valid.skip(1)) {
    final dNew = (folded[i]! - bpm).abs();
    final dOld = (folded[winner]! - bpm).abs();
    if (dNew < dOld - 1e-9 ||
        ((dNew - dOld).abs() <= 1e-9 &&
            (grids[i].confidence > grids[winner].confidence ||
                (grids[i].confidence == grids[winner].confidence &&
                    i == 1)))) {
      winner = i;
    }
  }
  return (
    bpm: bpm,
    confidence: confidence,
    winner: winner,
    agreed: true,
    folded: [for (final i in valid) folded[i]!],
    halved: halved,
  );
}
