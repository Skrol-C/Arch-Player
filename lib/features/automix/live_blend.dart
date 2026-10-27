// Live-blend gain math: the baked recipe's volume envelopes as pure
// Dart, shared by the just_audio live engine (and proven on the
// media_kit spike). A falls on cos() over the last ~85%, B rises on
// sin() across the bridge, with the same 6dB duck terms where both
// sing. The sum passes through a limiter ceiling (Android mixes two
// full-scale players with no sum bus — the baked alimiter's job).
import 'dart:math' as math;

import 'baked_blend.dart' show BlendPlan;

/// Live ceiling: baked sums then clamps peaks at 0.95; live clamps at
/// 1.15 — the Android mixer tolerates mild overs without the hard
/// clip that printed static on the spike.
const liveSumCeiling = 1.15;

/// Recipe volumes at bridge time [t] (seconds). Pure, deterministic.
({double a, double b}) liveGains(BlendPlan plan, double t) {
  final d = plan.seconds;
  final tt = t.clamp(0.0, d);
  final fadeA = d * 0.85;
  var aEnv = math.cos(math.pi / 2 * math.min(tt / fadeA, 1.0));
  if (plan.ducks.isNotEmpty) {
    var duck = 0.0;
    for (final w in plan.ducks) {
      final up =
          math.min(math.max((tt - (w.$1 - 0.5)) / 0.5, 0.0), 1.0);
      final dn =
          math.min(math.max(((w.$2 + 0.5) - tt) / 0.5, 0.0), 1.0);
      duck += up * dn;
    }
    duck = duck.clamp(0.0, 1.0);
    aEnv = aEnv * (1 - 0.5 * duck);
  }
  final bEnv = math.sin(math.pi / 2 * (tt / d).clamp(0.0, 1.0));
  return (a: aEnv.clamp(0.0, 1.0), b: bEnv.clamp(0.0, 1.0));
}

/// Limiter: when the lane sum exceeds the ceiling both lanes share
/// the cut. Ends stay full level, only true peaks dip.
({double a, double b}) limitedGains(
  ({double a, double b}) g, [
  double ceiling = liveSumCeiling,
]) {
  final s = g.a + g.b;
  if (s <= ceiling) return g;
  final k = ceiling / s;
  return (a: g.a * k, b: g.b * k);
}
