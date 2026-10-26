// Beat grid for harmonic automix.
//
// Ported from Mornye (mornyeapp/Mornye, MIT):
// rust_backend/crates/core/src/native_audio_analysis.rs
// (analyze_automix_pcm / AutoMixBeatGrid), adopted with gratitude.
// Arithmetic order, thresholds and tie handling match the original;
// only the language changed. Original remains MIT; this file rides
// with the project's GPL-3.0 (see LICENSE).
//
// What it does: mono 16-bit PCM at 11,025 Hz in, {bpm, phase,
// confidence, first_sound} out. Three-band onset envelope, local
// normalization, autocorrelation sweep 60-180 BPM with a 120 prior,
// fine refine, phase search. No DSP dependencies, no unsafe.

import 'dart:math' as math;
import 'dart:typed_data';

/// Beat grid for one track: tempo, beat phase (seconds), confidence
/// and the first audible sound — the inputs phrase-aware crossfades
/// need. All zeros = unknown (silence, too short, no reliable beat).
class AutoMixBeatGrid {
  final double bpm;
  final double phase;
  final double confidence;
  final double firstSound;

  const AutoMixBeatGrid({
    this.bpm = 0,
    this.phase = 0,
    this.confidence = 0,
    this.firstSound = 0,
  });
}

/// Max input: ~25s of mono 16-bit PCM at 11,025 Hz. Callers bound
/// the decode (ffmpeg `-t 25`); oversize throws.
const _maxPcmBytes = 11025 * 2 * 25;
const _hop = 128;
const _fps = 11025.0 / _hop;

AutoMixBeatGrid analyzeAutomixPcm(Uint8List pcm) {
  if (pcm.length > _maxPcmBytes) {
    throw ArgumentError('AutoMix PCM exceeds the size limit');
  }
  final frames = pcm.length ~/ (2 * _hop);
  if (frames < _fps * 6.0) return const AutoMixBeatGrid();
  final data =
      ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes);
  final onset = List<double>.filled(frames, 0.0);
  final energy = List<double>.filled(frames, 0.0);
  var low = 0.0;
  var mid = 0.0;
  var prevLow = 0.0;
  var prevMid = 0.0;
  var prevHigh = 0.0;
  for (var frame = 0; frame < frames; frame++) {
    var loEnergy = 0.0;
    var midEnergy = 0.0;
    var hiEnergy = 0.0;
    for (var index = 0; index < _hop; index++) {
      final byte = (frame * _hop + index) * 2;
      final value = data.getInt16(byte, Endian.little) / 32768.0;
      low += 0.075 * (value - low);
      mid += 0.45 * (value - mid);
      loEnergy += low * low;
      midEnergy += (mid - low) * (mid - low);
      hiEnergy += (value - mid) * (value - mid);
      energy[frame] += value * value / _hop;
    }
    final lo = math.log(1.0 + loEnergy * 100.0 / _hop);
    final mi = math.log(1.0 + midEnergy * 100.0 / _hop);
    final hi = math.log(1.0 + hiEnergy * 100.0 / _hop);
    onset[frame] = math.max(lo - prevLow, 0.0) +
        math.max(mi - prevMid, 0.0) +
        0.5 * math.max(hi - prevHigh, 0.0);
    prevLow = lo;
    prevMid = mi;
    prevHigh = hi;
  }
  final peakEnergy = energy.reduce(math.max);
  if (peakEnergy < 0.00001) return const AutoMixBeatGrid();
  final floorEnergy = math.max(0.00001, peakEnergy * 0.0001);
  final firstAudible = energy.indexWhere((value) => value > floorEnergy);
  final firstSound = (firstAudible < 0 ? 0 : firstAudible) / _fps;
  final prefix = List<double>.filled(frames + 1, 0.0);
  for (var index = 0; index < frames; index++) {
    prefix[index + 1] = prefix[index] + onset[index];
  }
  var total = 0.0;
  for (var index = 0; index < frames; index++) {
    final begin = math.max(index - 8, 0);
    final end = math.min(index + 9, frames);
    onset[index] =
        math.max(onset[index] - (prefix[end] - prefix[begin]) / (end - begin), 0.0);
    total += onset[index] * onset[index];
  }
  if (total < 0.000001) {
    return AutoMixBeatGrid(firstSound: firstSound);
  }
  final power = List<double>.filled(frames + 1, 0.0);
  for (var index = 0; index < frames; index++) {
    power[index + 1] = power[index] + onset[index] * onset[index];
  }
  final floor = total / frames * 0.01;
  for (var index = 0; index < frames; index++) {
    final begin = math.max(index - 43, 0);
    final end = math.min(index + 44, frames);
    final local = (power[end] - power[begin]) / (end - begin);
    onset[index] = math.min(onset[index] / math.sqrt(math.max(floor, local)), 6.0);
  }
  double correlation(double lag) {
    var dot = 0.0;
    var left = 0.0;
    var right = 0.0;
    for (var index = lag.ceil(); index < frames; index++) {
      final source = index - lag;
      final previous = source.floor();
      final fraction = source - previous;
      final delayed = onset[previous] * (1.0 - fraction) +
          onset[math.min(previous + 1, frames - 1)] * fraction;
      dot += onset[index] * delayed;
      left += onset[index] * onset[index];
      right += delayed * delayed;
    }
    return dot / math.sqrt(math.max(left * right, 0.000000001));
  }

  double weighted(double bpm, double score) {
    // Verbatim shape: the exp binds to the inner term, i.e.
    // score * (0.96 + 0.04 * exp(-d*d)) — a gentle ±2% preference
    // centered on 120 BPM, not a 2.6x boost. One misplaced paren
    // here cost a day; the oracle numbers prove this form.
    final d = (bpm - 120.0) / 45.0;
    return score * (0.96 + 0.04 * math.exp(-d * d));
  }

  var bestBpm = 0.0;
  var bestScore = 0.0;
  for (var quarterBpm = 240; quarterBpm <= 720; quarterBpm++) {
    final bpm = quarterBpm / 4.0;
    final score = correlation(_fps * 60.0 / bpm);
    final w = weighted(bpm, score);
    if (w > bestScore) {
      bestScore = w;
      bestBpm = bpm;
    }
  }
  if (bestBpm == 0.0) return const AutoMixBeatGrid();
  final coarseBpm = bestBpm;
  for (var step = -25; step <= 25; step++) {
    final bpm = coarseBpm + step * 0.01;
    if (bpm < 60.0 || bpm > 180.0) continue;
    final score = correlation(_fps * 60.0 / bpm);
    final w = weighted(bpm, score);
    if (w > bestScore) {
      bestScore = w;
      bestBpm = bpm;
    }
  }
  final period = _fps * 60.0 / bestBpm;
  var bestPhase = 0.0;
  var phaseScore = 0.0;
  var phase = 0.0;
  while (phase < period) {
    var score = 0.0;
    var count = 0;
    var beat = phase;
    while (beat < frames - 1) {
      score += onset[beat.round()];
      count++;
      beat += period;
    }
    score /= math.max(count, 1);
    if (score > phaseScore) {
      phaseScore = score;
      bestPhase = phase;
    }
    phase += 0.5;
  }
  var hits = 0;
  var beats = 0;
  var beat = bestPhase;
  while (beat < frames - 2) {
    final index = beat.round();
    final peak = math.max(
      onset[index],
      math.max(onset[math.max(index - 1, 0)], onset[index + 1]),
    );
    if (peak >= phaseScore * 0.3) hits++;
    beats++;
    beat += period;
  }
  return AutoMixBeatGrid(
    bpm: bestBpm,
    phase: bestPhase / _fps,
    confidence: math.min(bestScore, hits / math.max(beats, 1)),
    firstSound: firstSound,
  );
}

/// Low-band-only beat coverage: fraction of grid beats (at [bpm]
/// from [phase], seconds) that carry a low-end transient. Same one-pole
/// low band as the tempo detector (~130 Hz cutoff), so hats and
/// sibilance don't vote — only kicks, bass drops and low toms.
///
/// Used for the octave tie-break: when a minority window hears ~2x the
/// consensus, strong low-band coverage at the faster grid means the
/// track is really at the faster tempo (four-on-the-floor counted at
/// half time); weak coverage means a genuine half-time feel.
double lowBandCoverage(Uint8List pcm, double bpm, double phase) {
  if (bpm <= 0) return 0.0;
  final frames = pcm.length ~/ (2 * _hop);
  if (frames < _fps * 2.0) return 0.0;
  final data =
      ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes);
  final onset = List<double>.filled(frames, 0.0);
  var low = 0.0;
  var prevLow = 0.0;
  for (var frame = 0; frame < frames; frame++) {
    var loEnergy = 0.0;
    for (var index = 0; index < _hop; index++) {
      final byte = (frame * _hop + index) * 2;
      final value = data.getInt16(byte, Endian.little) / 32768.0;
      low += 0.075 * (value - low);
      loEnergy += low * low;
    }
    final lo = math.log(1.0 + loEnergy * 100.0 / _hop);
    onset[frame] = math.max(lo - prevLow, 0.0);
    prevLow = lo;
  }
  final period = _fps * 60.0 / bpm;
  final start = (phase * _fps).round();
  var score = 0.0;
  var beats = 0;
  var beat = start.toDouble();
  while (beat < frames - 1) {
    score += onset[beat.round().clamp(0, frames - 1)];
    beats++;
    beat += period;
  }
  if (beats == 0) return 0.0;
  score /= beats;
  if (score <= 0.0) return 0.0;
  var hits = 0;
  var total = 0;
  beat = start.toDouble();
  while (beat < frames - 2) {
    final index = beat.round().clamp(1, frames - 2);
    final peak = math.max(
      onset[index],
      math.max(onset[index - 1], onset[index + 1]),
    );
    if (peak >= score * 0.3) hits++;
    total++;
    beat += period;
  }
  return hits / math.max(total, 1);
}

/// Octave tie-break: take the faster octave only when the low band
/// carries it nearly as well as the slower one. Deliberately strict —
/// a wrong flip-up is worse than a held half.
bool preferDouble(double covSlow, double covFast) =>
    covFast >= 0.7 && covFast >= covSlow * 0.85;
