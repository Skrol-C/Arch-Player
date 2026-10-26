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

  test('genuine disagreement falls back to best confidence', () {
    final c = consensusTempo([_g(120, 0.9), _g(100, 0.95), _g(140, 0.8)]);
    expect(c.bpm, closeTo(100.0, 0.01));
    expect(c.confidence, closeTo(0.95, 0.01));
    expect(c.winner, 1);
    expect(c.agreed, isFalse);
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
}
