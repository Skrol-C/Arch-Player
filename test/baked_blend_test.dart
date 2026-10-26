import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/baked_blend.dart';

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
    // Filter carries the whole recipe.
    expect(p.filter, contains('highpass=f=120'));
    expect(p.filter, contains('atempo='));
    expect(p.filter, contains('adelay='));
    expect(p.filter, contains('amix=inputs=2'));
    expect(p.filter, contains('alimiter'));
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

  test('unbridgeable pairs return null, never garbage', () {
    // Missing tempo.
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
}
