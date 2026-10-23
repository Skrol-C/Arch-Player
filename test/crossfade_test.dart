import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/crossfade.dart';

void main() {
  test('same Camelot code blends longest', () {
    final p = planCrossfade(openA: '8m', openB: '8m', bpmA: 128, bpmB: 128);
    expect(p.seconds, 9.0);
    expect(p.reason, 'same+tight tempo');
  });

  test('relative major/minor is legal but shorter', () {
    final p = planCrossfade(openA: '8m', openB: '8d', bpmA: 120, bpmB: 120);
    expect(p.seconds, 7.5);
    expect(p.reason, 'relative+tight tempo');
  });

  test('one step around the wheel', () {
    final p = planCrossfade(openA: '8m', openB: '9m', bpmA: 120, bpmB: 124);
    expect(p.seconds, 6.0);
    expect(p.reason, 'adjacent');
  });

  test('two steps is an energy lift', () {
    final p = planCrossfade(openA: '8m', openB: '10m', bpmA: 120, bpmB: 124);
    expect(p.seconds, 4.5);
  });

  test('far keys get the shortest legal blend', () {
    final p = planCrossfade(openA: '8m', openB: '2d', bpmA: 120, bpmB: 124);
    expect(p.seconds, 4.0);
    expect(p.reason, 'far');
  });

  test('tempo clash outranks a perfect key match', () {
    final p = planCrossfade(openA: '8m', openB: '8m', bpmA: 128, bpmB: 170);
    expect(p.seconds, 4.0);
    expect(p.reason, 'tempo gap');
  });

  test('half/double time is not a tempo clash', () {
    final p = planCrossfade(openA: '8m', openB: '8m', bpmA: 70, bpmB: 140);
    expect(p.reason, isNot('tempo gap'));
    expect(p.seconds, 9.0);
  });

  test('unknowns stay in the neutral middle', () {
    expect(planCrossfade().seconds, crossfadeNeutral);
    expect(planCrossfade(openA: 'nope').seconds, crossfadeNeutral);
    expect(
      planCrossfade(openA: '8m', openB: null, bpmA: 128).seconds,
      crossfadeNeutral,
    );
  });

  test('every plan stays inside the legal band', () {
    for (final bpm in [40.0, 70.0, 128.0, 200.0]) {
      for (final key in ['1m', '8m', '8d', '12d']) {
        final p = planCrossfade(openA: '8m', openB: key, bpmA: bpm, bpmB: bpm);
        expect(p.seconds, greaterThanOrEqualTo(crossfadeMin));
        expect(p.seconds, lessThanOrEqualTo(crossfadeMax));
      }
    }
  });

  test('equal-power gains sum flat and hit the rails', () {
    final start = crossfadeGains(0);
    expect(start.out, closeTo(1.0, 1e-9));
    expect(start.in_, closeTo(0.0, 1e-9));
    final end = crossfadeGains(1);
    expect(end.out, closeTo(0.0, 1e-9));
    expect(end.in_, closeTo(1.0, 1e-9));
    // Power stays constant: no mid-blend hole.
    for (var i = 0; i <= 10; i++) {
      final g = crossfadeGains(i / 10);
      expect(g.out * g.out + g.in_ * g.in_, closeTo(1.0, 1e-9));
      // Equal-power never dips below the linear fade's -6 dB point.
      expect(g.out + g.in_, greaterThanOrEqualTo(1.0 - 1e-9));
    }
    expect(crossfadeGains(0.5).out, closeTo(math.sqrt1_2, 1e-9));
  });

  test('gains clamp outside 0..1', () {
    expect(crossfadeGains(-1).out, 1.0);
    expect(crossfadeGains(2).in_, 1.0);
  });
}
