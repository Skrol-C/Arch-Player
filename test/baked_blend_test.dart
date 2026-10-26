import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/baked_blend.dart';
import 'package:arch_player/features/automix/beat_grid.dart';

/// Prototype pair numbers: BLOODY STREAM (131.31) -> Give Me Everything
/// (130.76). Same key, 0.4% gap.
BlendSpec _proto() => const BlendSpec(
  aPath: '/music/a.flac',
  bPath: '/music/b.flac',
  durA: 260.0,
  durB: 251.0,
  bpmA: 131.31,
  bpmB: 130.76,
  phaseA: 0.1,
  phaseB: 0.05,
  firstSoundB: 0.3,
);

void main() {
  test('prototype pair plans an aligned bridge', () {
    final plan = buildBlend(_proto());
    expect(plan, isNotNull);
    final p = plan!;
    final periodA = 60.0 / 131.31;
    // Entry delay sits inside one A period: B lands on an A beat.
    expect(p.entryDelay, greaterThanOrEqualTo(0.0));
    expect(p.entryDelay, lessThan(periodA));
    // B starts on its grid at/after first sound, within one period.
    expect(p.startB, greaterThanOrEqualTo(0.3));
    expect(p.startB - 0.3, lessThan(60.0 / 130.76));
    // Tempo ratio matches B to A almost exactly.
    expect(p.tempoRatio, closeTo(131.31 / 130.76, 0.000001));
    // Overlap is 8 bars at A's tempo.
    expect(p.seconds, closeTo(8 * 4 * periodA, 0.01));
    // Bridge grids coincide: B beats land on A beats.
    final periodBs = (60.0 / 130.76) / p.tempoRatio;
    expect(periodBs, closeTo(periodA, 0.000001));
    // Filter carries the whole recipe: steep bass cut on A, biased
    // exit, tempo-matched B delayed onto an A beat.
    expect(p.filter, contains('highpass=f=160'));
    expect(p.filter, contains('atempo='));
    expect(p.filter, contains('adelay='));
    expect(p.filter, contains('amix=inputs=2'));
    expect(p.filter, contains('alimiter'));
    expect(p.filter, contains('min(t/'));
  });

  test('unknown geometry degrades to zero-start', () {
    const spec = BlendSpec(
      aPath: '/a',
      bPath: '/b',
      durA: 200.0,
      durB: 200.0,
      bpmA: 120.0,
      bpmB: 120.0,
    );
    final plan = buildBlend(spec);
    expect(plan, isNotNull);
    expect(plan!.startB, closeTo(0.0, 0.001));
    expect(plan.tempoRatio, closeTo(1.0, 0.000001));
  });

  test('unbridgeable pairs return null, never garbage', () {    // Missing tempo.
    expect(
      buildBlend(
        const BlendSpec(
          aPath: '/a',
          bPath: '/b',
          durA: 200.0,
          durB: 200.0,
          bpmA: 0.0,
          bpmB: 120.0,
        ),
      ),
      isNull,
    );
    // Tempo gap beyond the atempo lane.
    expect(
      buildBlend(
        const BlendSpec(
          aPath: '/a',
          bPath: '/b',
          durA: 200.0,
          durB: 200.0,
          bpmA: 100.0,
          bpmB: 150.0,
        ),
      ),
      isNull,
    );
    // A shorter than the window.
    expect(
      buildBlend(
        const BlendSpec(
          aPath: '/a',
          bPath: '/b',
          durA: 10.0,
          durB: 200.0,
          bpmA: 120.0,
          bpmB: 120.0,
        ),
      ),
      isNull,
    );
    // B runs out inside the window.
    expect(
      buildBlend(
        const BlendSpec(
          aPath: '/a',
          bPath: '/b',
          durA: 200.0,
          durB: 5.0,
          bpmA: 120.0,
          bpmB: 120.0,
          phaseB: 0.0,
          firstSoundB: 0.0,
        ),
      ),
      isNull,
    );
  });

  test('mix-in skips intro silence to the groove', () {
    // 4s of silence, then 120 BPM low thumps: groove starts at 4.0s.
    final pcm = _silenceThenThumps(120.0, 4.0, 12.0);
    expect(findMixIn(pcm, 120.0, 0.0, 0.0), closeTo(4.0, 0.05));
  });

  test('mix-in stays put when the groove starts at zero', () {
    final pcm = _silenceThenThumps(120.0, 0.0, 8.0);
    expect(findMixIn(pcm, 120.0, 0.0, 0.0), closeTo(0.0, 0.05));
  });

  test('mix-in never precedes first sound', () {
    final pcm = _silenceThenThumps(90.0, 2.0, 10.0);
    // First sound at 2.0 is ambience-free here, so the groove is it.
    expect(findMixIn(pcm, 90.0, 0.0, 2.0), closeTo(2.0, 0.1));
  });

  test('mix-out cuts trailing dead air at the groove', () {
    // Groove to 8.0s, then silence. The cut zeroes the boundary
    // thump itself, so the last intact groove beat is 7.5s.
    final pcm = _thumpsThenSilence(120.0, 8.0, 12.0);
    expect(findMixOut(pcm, 120.0, 0.0, 12.0), closeTo(7.5, 0.05));
  });

  test('mix-out holds through groove to the end', () {
    final pcm = _thumpsThenSilence(120.0, 8.0, 8.0);
    expect(findMixOut(pcm, 120.0, 0.0, 8.0), closeTo(7.5, 0.05));
  });

  test('mix-out keeps absurdly long outros', () {
    // Groove ends at 10s but the file runs a minute: live ending or
    // applause — don't time-travel, keep the tail.
    final pcm = _thumpsThenSilence(120.0, 10.0, 60.0);
    expect(findMixOut(pcm, 120.0, 0.0, 60.0), closeTo(60.0, 0.01));
  });

  test('bridge window ends at the mix-out point', () {
    const spec = BlendSpec(
      aPath: '/a',
      bPath: '/b',
      durA: 260.0,
      durB: 251.0,
      bpmA: 120.0,
      bpmB: 120.0,
      phaseA: 0.0,
      phaseB: 0.0,
      firstSoundB: 0.0,
      endA: 240.0,
      bars: 8,
    );
    final plan = buildBlend(spec);
    expect(plan, isNotNull);
    // 8 bars at 120 BPM = 16s window ending at 240 -> starts at 224.
    expect(plan!.filter, contains('start=224.000'));
  });
}

/// Low thumps after [silentSecs] of digital silence: intros that lie.
Uint8List _silenceThenThumps(double bpm, double silentSecs, double totalSecs) {
  final pcm = <int>[];
  final total = (11025 * totalSecs).round();
  final period = 60.0 / bpm;
  for (var i = 0; i < total; i++) {
    final time = i / 11025.0;
    var value = 0.0;
    if (time >= silentSecs) {
      final since = (time - silentSecs) % period;
      // Snap groove to the grid: first thump exactly at silentSecs
      // when it divides evenly (test picks values that do).
      final transient = math.exp(-since * 60.0);
      value = 0.8 * transient * math.sin(time * 2.0 * math.pi * 90.0);
    }
    final s = (value * 32767.0).round().clamp(-32768, 32767);
    pcm
      ..add(s & 0xFF)
      ..add((s >> 8) & 0xFF);
  }
  return Uint8List.fromList(pcm);
}

/// Groove until [grooveSecs], then digital silence: dead outros.
Uint8List _thumpsThenSilence(
  double bpm,
  double grooveSecs,
  double totalSecs,
) {
  final pcm = _silenceThenThumps(bpm, 0.0, totalSecs);
  final cut = (11025 * grooveSecs).round() * 2;
  for (var i = cut; i < pcm.length; i++) {
    pcm[i] = 0;
  }
  return pcm;
}
