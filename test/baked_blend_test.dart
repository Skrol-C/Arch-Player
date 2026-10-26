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

  test('bridge window ends at the mix-out point', () {    const spec = BlendSpec(
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

  test('vocal windows map both grids into file time', () {
    // A sings track-time 235-238 of a window starting at 224
    // (-> file 11-14). B sings 12-14, starting at 0.5 with no
    // stretch and 0.2s entry (-> file 11.7-13.7). Overlap ducks.
    final windows = vocalDuckWindows(
      vocalA: const [(235.0, 238.0)],
      vocalB: const [(12.0, 14.0)],
      aStart: 224.0,
      bStart: 0.5,
      delay: 0.2,
      rate: 1.0,
      length: 16.0,
    );
    expect(windows, hasLength(1));
    expect(windows.single.$1, closeTo(11.7, 0.01));
    expect(windows.single.$2, closeTo(13.7, 0.01));
  });

  test('B windows map through the atempo stretch', () {
    // Same geometry at 1.25x: (12.5-0.5)/1.25 + 0.2 = 9.8 start.
    final windows = vocalDuckWindows(
      vocalA: null,
      vocalB: const [(12.5, 16.5)],
      aStart: 224.0,
      bStart: 0.5,
      delay: 0.2,
      rate: 1.25,
      length: 16.0,
    );
    expect(windows, hasLength(1));
    expect(windows.single.$1, closeTo(9.8, 0.01));
    expect(windows.single.$2, closeTo(13.0, 0.01));
  });

  test('overlapping vocal windows intersect', () {
    // A sings file-time 6-8; B lands its 12-14 on the same span.
    final windows = vocalDuckWindows(
      vocalA: const [(230.0, 232.0)],
      vocalB: const [(12.0, 14.0)],
      aStart: 224.0,
      bStart: 6.0,
      delay: 0.0,
      rate: 1.0,
      length: 16.0,
    );
    expect(windows, hasLength(1));
    expect(windows.single.$1, closeTo(6.0, 0.001));
    expect(windows.single.$2, closeTo(8.0, 0.001));
  });

  test('unknown A vocals duck the whole B window', () {
    final windows = vocalDuckWindows(
      vocalA: null,
      vocalB: const [(12.0, 14.0)],
      aStart: 224.0,
      bStart: 0.5,
      delay: 0.2,
      rate: 1.0,
      length: 16.0,
    );
    expect(windows, hasLength(1));
    expect(windows.single.$1, closeTo(11.7, 0.001));
    expect(windows.single.$2, closeTo(13.7, 0.001));
  });

  test('known instrumental A never ducks', () {
    final windows = vocalDuckWindows(
      vocalA: const [],
      vocalB: const [(12.0, 14.0)],
      aStart: 224.0,
      bStart: 0.5,
      delay: 0.2,
      rate: 1.0,
      length: 16.0,
    );
    expect(windows, isEmpty);
  });

  test('ducking enters the A filter only on clash', () {
    const base = BlendSpec(
      aPath: '/a',
      bPath: '/b',
      durA: 260.0,
      durB: 251.0,
      bpmA: 120.0,
      bpmB: 120.0,
      phaseA: 0.0,
      phaseB: 0.0,
      firstSoundB: 0.0,
      bars: 8,
    );
    // No vocals anywhere: plain equal-power exit.
    final plain = buildBlend(base);
    expect(planHasDuck(plain!), isFalse);
    // B sings 2-6 (track time, from mix-in at 0): A unknown -> duck.
    final ducked = buildBlend(
      const BlendSpec(
        aPath: '/a',
        bPath: '/b',
        durA: 260.0,
        durB: 251.0,
        bpmA: 120.0,
        bpmB: 120.0,
        phaseA: 0.0,
        phaseB: 0.0,
        firstSoundB: 0.0,
        vocalB: [(2.0, 6.0)],
        bars: 8,
      ),
    );
    expect(ducked, isNotNull);
    expect(planHasDuck(ducked!), isTrue);
    expect(ducked.ducks, hasLength(1));
  });

  test('vocal talk trim cuts outro rambling', () {
    // Groove runs to 240, but talking starts at 232 and runs past
    // the groove: the bridge ends where the talking starts.
    expect(
      vocalTalkCut(
        grooveEnd: 240.0,
        durA: 260.0,
        vocalA: const [(232.0, 250.0)],
        minEnd: 20.0,
      ),
      closeTo(232.0, 0.001),
    );
    // Talking that ends with the groove is no reason to cut.
    expect(
      vocalTalkCut(
        grooveEnd: 240.0,
        durA: 260.0,
        vocalA: const [(200.0, 239.0)],
        minEnd: 20.0,
      ),
      closeTo(240.0, 0.001),
    );
    // Unknown vocals: no information, no cut.
    expect(
      vocalTalkCut(
        grooveEnd: 240.0,
        durA: 260.0,
        vocalA: null,
        minEnd: 20.0,
      ),
      closeTo(240.0, 0.001),
    );
    // Mid-song vocals far from the outro: not outro talk.
    expect(
      vocalTalkCut(
        grooveEnd: 240.0,
        durA: 260.0,
        vocalA: const [(100.0, 120.0)],
        minEnd: 20.0,
      ),
      closeTo(240.0, 0.001),
    );
  });

  test('vocal clash steps long blends down', () {
    // 32 requested but vocal clash covers most of the window:
    // A sings track 140-170 (window starts at 136), B sings
    // throughout. Falls back until the clash fits.
    const clashy = BlendSpec(
      aPath: '/a',
      bPath: '/b',
      durA: 200.0,
      durB: 200.0,
      bpmA: 120.0,
      bpmB: 120.0,
      phaseA: 0.0,
      phaseB: 0.0,
      firstSoundB: 0.0,
      vocalA: [(140.0, 170.0)],
      vocalB: [(0.0, 40.0)],
      bars: 32,
    );
    final stepped = buildBestBlend(clashy);
    expect(stepped, isNotNull);
    // 32 bars clash at 47%; 16 bars clash at 6%: steps to 16.
    expect(stepped!.bars, 16);
    // No vocal data anywhere: requested length stands.
    final plain = buildBestBlend(
      const BlendSpec(
        aPath: '/a',
        bPath: '/b',
        durA: 200.0,
        durB: 200.0,
        bpmA: 120.0,
        bpmB: 120.0,
        phaseA: 0.0,
        phaseB: 0.0,
        firstSoundB: 0.0,
        bars: 32,
      ),
    );
    expect(plain, isNotNull);
    expect(plain!.bars, 32);
    // Unbridgeable at every length stays null, honestly.
    expect(
      buildBestBlend(
        const BlendSpec(
          aPath: '/a',
          bPath: '/b',
          durA: 1.0,
          durB: 200.0,
          bpmA: 120.0,
          bpmB: 120.0,
          bars: 32,
        ),
      ),
      isNull,
    );
  });
}

/// The dip marker distinguishes a ducked A exit from plain equal-power.
bool planHasDuck(BlendPlan p) => p.filter.contains('1-0.5*(');

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
