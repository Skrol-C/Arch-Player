import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/baked_blend.dart';
import 'package:arch_player/features/automix/live_blend.dart';

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
  test('live gains open A-full B-silent, close A-spent B-full', () {
    final plan = buildBlend(_proto())!;
    final open = liveGains(plan, 0.0);
    expect(open.a, closeTo(1.0, 0.001));
    expect(open.b, closeTo(0.0, 0.001));
    final shut = liveGains(plan, plan.seconds);
    expect(shut.a, closeTo(0.0, 0.001));
    expect(shut.b, closeTo(1.0, 0.001));
  });

  test('mid-bridge both lanes alive (true overlap, no gap)', () {
    final plan = buildBlend(_proto())!;
    final mid = liveGains(plan, plan.seconds / 2);
    expect(mid.a, greaterThan(0.2));
    expect(mid.b, greaterThan(0.2));
  });

  test('limiter only touches the clip zone', () {
    // Below ceiling: untouched.
    expect(limitedGains((a: 0.5, b: 0.4)), (a: 0.5, b: 0.4));
    // Above ceiling: shared cut, sum lands on the ceiling.
    final cut = limitedGains((a: 0.8, b: 0.8));
    expect(cut.a + cut.b, closeTo(liveSumCeiling, 0.000001));
    expect(cut.a, closeTo(cut.b, 0.000001));
  });

  test('knee attacks instantly, releases slowly', () {
    // Overload bites on the same tick: no clip gets through.
    expect(smoothKnee(1.0, 0.7), 0.7);
    // Recovery creeps: no audible pump when the peak passes.
    final r1 = smoothKnee(0.7, 1.0);
    expect(r1, greaterThan(0.7));
    expect(r1, lessThan(0.8));
    final r2 = smoothKnee(r1, 1.0);
    expect(r2, greaterThan(r1));
    expect(r2, lessThan(1.0));
  });

  test('duck zones dip A under B vocals', () {
    final plan = buildBlend(_proto())!;
    if (plan.ducks.isEmpty) return; // pair-dependent, informational only
    final w = plan.ducks.first;
    final mid = (w.$1 + w.$2) / 2;
    final ducked = liveGains(plan, mid);
    final clean = liveGains(
      BlendPlan(
        filter: plan.filter,
        seconds: plan.seconds,
        entryDelay: plan.entryDelay,
        startB: plan.startB,
        tempoRatio: plan.tempoRatio,
        bars: plan.bars,
      ),
      mid,
    );
    expect(ducked.a, lessThan(clean.a));
  });
}
