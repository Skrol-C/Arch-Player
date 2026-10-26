import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/automix_pcm.dart';
import 'package:arch_player/features/automix/beat_grid.dart';

AutoMixBeatGrid _g(double bpm, double confidence) =>
    AutoMixBeatGrid(bpm: bpm, confidence: confidence);

void main() {
  test('half-time window folds up to the consensus', () {
    final c = consensusTempo([_g(120, 0.9), _g(60, 0.8), _g(120, 0.7)]);
    expect(c.bpm, closeTo(120.0, 0.01));
    expect(c.confidence, closeTo(0.9, 0.01));
    expect(c.winner, 0);
    expect(c.agreed, isTrue);
  });

  test('double-time window folds down to the consensus', () {
    final c = consensusTempo([_g(131, 0.7), _g(262, 0.9), _g(131, 0.8)]);
    expect(c.bpm, closeTo(131.0, 0.01));
    // Winner: all fold to 131, so most confident wins.
    expect(c.winner, 1);
  });

  test('4/3 harmonic folds down by 3/4', () {
    // 160 = 4/3 x 120: median 120, ratio 0.75, scaled back to 120.
    final c = consensusTempo([_g(160, 0.9), _g(120, 0.8), _g(120, 0.7)]);
    expect(c.bpm, closeTo(120.0, 0.01));
  });

  test('3/4 harmonic folds up by 4/3', () {
    // 90 = 3/4 x 120: median 120, ratio 1.33, scaled back to 120.
    final c = consensusTempo([_g(90, 0.9), _g(120, 0.8), _g(120, 0.7)]);
    expect(c.bpm, closeTo(120.0, 0.01));
  });

  test('tight pair outvotes a wild third', () {
    // BLOODY STREAM on device: 175.3 folds to 131.5, joins 131.2.
    // Online consensus: 130-132. The rescue validates.
    final c = consensusTempo([_g(175.3, 0.4), _g(131.2, 0.35), _g(115.9, 0.3)]);
    expect(c.agreed, isFalse);
    expect(c.pair, isTrue);
    expect(c.bpm, closeTo(131.34, 0.05));
    expect(c.confidence, greaterThan(0.55));
  });

  test('pair rejects manufactured agreement', () {
    // Sunlight on device: truth is 117, window one found 116.4 — but
    // the poisoned median folded it to 87.3, which then "confirmed" a
    // wrong 89.8. Folded values inherit the median, so their agreement
    // needs tighter tolerance. Right answer, honestly missed.
    final c = consensusTempo([_g(116.4, 0.38), _g(60.5, 0.3), _g(89.8, 0.32)]);
    expect(c.agreed, isFalse);
    expect(c.pair, isFalse);
    expect(c.bpm, closeTo(116.4, 0.01));
    expect(c.confidence, lessThan(0.55));
  });

  test('pair trusts a doubled majority', () {
    // STAKILLAZ on device: two windows agree ~174, third hears the fifth.
    final c = consensusTempo([_g(115.7, 0.51), _g(173.6, 0.4), _g(174.3, 0.38)]);
    expect(c.agreed, isFalse);
    expect(c.pair, isTrue);
    expect(c.bpm, closeTo(173.95, 0.05));
  });

  test('pair holds on scoreless drift', () {
    // I'm Big on device: orchestral, no beat — no pair agrees.
    final c = consensusTempo([_g(98.5, 0.3), _g(111.1, 0.35), _g(102.4, 0.3)]);
    expect(c.agreed, isFalse);
    expect(c.pair, isFalse);
    expect(c.bpm, closeTo(111.1, 0.01));
  });
  test('genuine disagreement falls back to best confidence', () {
    final c = consensusTempo([_g(120, 0.9), _g(100, 0.95), _g(140, 0.8)]);
    expect(c.bpm, closeTo(100.0, 0.01));
    expect(c.confidence, closeTo(0.95, 0.01));
    expect(c.winner, 1);
    expect(c.agreed, isFalse);
  });

  test('fallback still reports what folding attempted', () {
    // Wee Gee on device: median poisoned, no pair agrees.
    final c = consensusTempo([_g(169.6, 0.5), _g(91.3, 0.44), _g(138.2, 0.4)]);
    expect(c.agreed, isFalse);
    expect(c.folded[0], closeTo(127.2, 0.05));
    expect(c.folded[1], closeTo(91.3, 0.01));
    expect(c.folded[2], closeTo(138.2, 0.01));
  });

  test('single valid window keeps best-wins', () {
    final c = consensusTempo([_g(0, 0), _g(128, 0.8), _g(0, 0)]);
    expect(c.bpm, closeTo(128.0, 0.01));
    expect(c.winner, 1);
  });

  test('spread docks confidence, never below zero', () {
    // Folded [118, 122, 120]: std 2 -> dock 0.1 off the max.
    final c = consensusTempo([_g(118, 0.9), _g(122, 0.8), _g(120, 0.85)]);
    expect(c.bpm, closeTo(120.0, 0.01));
    expect(c.confidence, closeTo(0.818, 0.005));
  });

  test('agreement rescues starved absolute scores', () {
    // Give Me Everything, on device: right answer, weak scores.
    final c = consensusTempo([_g(130.8, 0.31), _g(128.0, 0.28), _g(98.5, 0.25)]);
    expect(c.bpm, closeTo(130.8, 0.01));
    expect(c.agreed, isTrue);
    // DAD shape: 0.9 base docked by spread, not capped by the 0.31 max.
    expect(c.confidence, greaterThan(0.55));
    expect(c.confidence, closeTo(0.83, 0.02));
  });

  test('two agreeing slices earn less than three', () {
    final c = consensusTempo([_g(0, 0), _g(120, 0.4), _g(120, 0.35)]);
    expect(c.bpm, closeTo(120.0, 0.01));
    expect(c.agreed, isTrue);
    expect(c.confidence, closeTo(0.75, 0.01));
  });

  test('halved minority is reported for the tie-break', () {
    // The remix on device: majority half-time, one window right.
    final c = consensusTempo([_g(77.5, 0.8), _g(77.6, 0.85), _g(155.1, 0.7)]);
    expect(c.agreed, isTrue);
    expect(c.bpm, closeTo(77.6, 0.05));
    expect(c.halved, hasLength(1));
    expect(c.halved.single, closeTo(155.1, 0.01));
  });

  test('preferDouble demands kick-band support', () {
    // Four-on-the-floor counted at half: both grids carried.
    expect(preferDouble(0.95, 0.92), isTrue);
    // Genuine half-time feel: faster grid explains half the beats.
    expect(preferDouble(0.9, 0.5), isFalse);
    // Weak faster grid, however relatively close, never flips.
    expect(preferDouble(0.7, 0.65), isFalse);
  });

  test('low band coverage separates octaves', () {    // 155 BPM low thumps: both the 155 and 77.5 grids are carried.
    final fast = _thumps(155.0, 8.0);
    final covFast = lowBandCoverage(fast, 155.0, 0.0);
    final covSlow = lowBandCoverage(fast, 77.5, 0.0);
    expect(covFast, greaterThan(0.8));
    expect(covSlow, greaterThan(0.8));
    expect(preferDouble(covSlow, covFast), isTrue);
    // 70 BPM low thumps (half-time pattern): the 140 grid starves.
    final slow = _thumps(70.0, 8.0);
    final cov70 = lowBandCoverage(slow, 70.0, 0.0);
    final cov140 = lowBandCoverage(slow, 140.0, 0.0);
    expect(cov70, greaterThan(0.8));
    expect(cov140, lessThan(0.7));
    expect(preferDouble(cov70, cov140), isFalse);
  });

  test('low band tempo hears kicks alone', () {
    // Halves of these fall outside the 60-180 sweep, so the octave is
    // forced: this proves the estimator hears kicks, not that it
    // resolves octaves (uniform trains tie toward half — same as the
    // full-band detector; real downbeat accents break those ties).
    final ninety = lowBandTempo(_thumps(90.0, 8.0));
    expect(ninety.bpm, closeTo(90.0, 1.0));
    expect(ninety.score, greaterThanOrEqualTo(0.5));
    final seventy = lowBandTempo(_thumps(70.0, 8.0));
    expect(seventy.bpm, closeTo(70.0, 1.0));
    expect(seventy.score, greaterThanOrEqualTo(0.5));
  });

  test('kick-confirm rescues starved true readings', () {
    // Sunlight on device: window right at 116.4, score starved at 0.38.
    expect(kickConfirm(0.38, 116.4, 116.2, 0.7), closeTo(0.65, 0.01));
    // AISHA on device: right at 111.09, one point under the gate.
    expect(kickConfirm(0.54, 111.09, 111.3, 0.6), closeTo(0.65, 0.01));
    // Already-confident readings pass through untouched.
    expect(kickConfirm(0.9, 120.0, 120.5, 0.8), closeTo(0.9, 0.01));
    // Weak low-band pulse never launders a silence (I'm Big shape).
    expect(kickConfirm(0.35, 102.4, 98.0, 0.4), closeTo(0.35, 0.01));
    // Disagreeing low band stays out of the way.
    expect(kickConfirm(0.4, 100.0, 150.0, 0.8), closeTo(0.4, 0.01));
    // Silence in, silence out.
    expect(kickConfirm(0.0, 0.0, 0.0, 0.0), closeTo(0.0, 0.01));
  });

  test('mid band carries quarter-note content', () {
    // Burst attacks are broadband: the mid slice (snare/clap/chop
    // territory) must see the same grid as the low slice.
    final mid = midBandOnset(_thumps(90.0, 8.0));
    expect(gridCoverage(mid, 90.0, 0.0), greaterThan(0.5));
  });

  test('feel-double flips half-time drums, holds the genuine slow', () {
    // Walking On A Dream shape: quarters carried upstairs, kicks out.
    expect(feelDouble(63.4, 0.9, 0.85, 0.3), isTrue);
    // Genuine slow: off-quarters starved, nothing to flip to.
    expect(feelDouble(70.0, 0.9, 0.5, 0.3), isFalse);
    // Kicks carry the double: tie-break territory, not feel-double.
    expect(feelDouble(65.0, 0.9, 0.85, 0.7), isFalse);
    // Normal ranges never flip.
    expect(feelDouble(120.0, 0.9, 0.9, 0.3), isFalse);
  });
}

/// Low thumps on a [bpm] grid: 90 Hz sine bursts, 8s unless told
/// otherwise. Kicks by construction — the coverage probe's home turf.
Uint8List _thumps(double bpm, double seconds) {
  final pcm = <int>[];
  final total = (11025 * seconds).round();
  final period = 60.0 / bpm;
  for (var i = 0; i < total; i++) {
    final time = i / 11025.0;
    final since = time % period;
    final transient = math.exp(-since * 60.0);
    final value = 0.8 * transient * math.sin(time * 2.0 * math.pi * 90.0);
    final s = (value * 32767.0).round().clamp(-32768, 32767);
    pcm
      ..add(s & 0xFF)
      ..add((s >> 8) & 0xFF);
  }
  return Uint8List.fromList(pcm);
}
