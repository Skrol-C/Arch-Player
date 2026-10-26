// Crossfade planning: how long a blend should last and how the two
// gains travel. Pure, deterministic, no players involved — the
// runtime asks this module for a plan and then just executes it.
//
// Length is adaptive, never a global constant: the better two tracks
// fit harmonically, the longer the blend can breathe. Compatibility
// is read from Camelot open keys ('8m' / '8d') and BPM proximity.
// Unknowns get the neutral middle, so a missing analysis never
// produces a jarring cut or an endless sprawl.

import 'dart:math' as math;

/// One blend: [seconds] of overlap and the equal-power gain pair.
class CrossfadePlan {
  /// Overlap length in seconds (3..10).
  final double seconds;

  /// Why this length won, for logs and for tuning later.
  final String reason;

  const CrossfadePlan({required this.seconds, required this.reason});

  Duration get duration => Duration(milliseconds: (seconds * 1000).round());
}

/// Bounds. Never shorter than a beat or two, never longer than a
/// phrase — outside this band a blend either reads as a cut or as a
/// different song.
const crossfadeMin = 3.0;
const crossfadeMax = 10.0;

/// Neutral length for unknowns: long enough to feel deliberate,
/// short enough to never drag.
const crossfadeNeutral = 6.0;

/// Tempo gap past which no key relationship can save the blend —
/// without timestretch, clashing grids smear fast. 8%.
const _tempoGapLimit = 0.08;

/// Build the plan for one transition.
///
/// [openA]/[openB] are Camelot codes ('8m', '11d', ...); [bpmA]/[bpmB]
/// may be null when unknown. Every input is optional: a partial
/// picture degrades to the next rule down, never to a guess.
CrossfadePlan planCrossfade({
  String? openA,
  String? openB,
  double? bpmA,
  double? bpmB,
}) {
  final keyRel = _camelotRelation(openA, openB);
  final tempoGap = _tempoGap(bpmA, bpmB);

  // Tempo clash outranks key: two grids that diverge this far beat
  // against each other no matter how pretty the harmony is.
  if (tempoGap != null && tempoGap > _tempoGapLimit) {
    return const CrossfadePlan(seconds: 4.0, reason: 'tempo gap');
  }

  final base = switch (keyRel) {
    _KeyRel.same => 8.0,
    _KeyRel.relative => 6.5,
    _KeyRel.adjacent => 6.0,
    _KeyRel.energy => 4.5,
    _KeyRel.far => 4.0,
    _KeyRel.unknown => crossfadeNeutral,
  };

  // Tight tempo lets the blend run a touch longer; the reverse never
  // shortens below the key verdict (the gap rule already did that).
  var seconds = base;
  if (tempoGap != null && tempoGap < 0.02) {
    seconds += 1.0;
  }

  return CrossfadePlan(
    seconds: seconds.clamp(crossfadeMin, crossfadeMax),
    reason: tempoGap != null && tempoGap < 0.02
        ? '${keyRel.name}+tight tempo'
        : keyRel.name,
  );
}

enum _KeyRel { same, relative, adjacent, energy, far, unknown }

/// Blend length in bars for a baked bridge. Same inputs as the live
/// planner, longer windows: the closer the harmonic fit, the longer
/// the blend can breathe. Unknowns fall back to 8, never to 32 —
/// a bad 30-second blend is worse than a bad 8-bar one.
/// Arrangement room steps the pick down ([32,16,8,4]) so short tracks
/// never force a window they can't fill.
int blendBars({
  String? openA,
  String? openB,
  double? bpmA,
  double? bpmB,
  double durA = 0,
  double durB = 0,
}) {
  final keyRel = _camelotRelation(openA, openB);
  final tempoGap = _tempoGap(bpmA, bpmB);
  // Grids diverge: keep it short no matter the harmony.
  if (tempoGap != null && tempoGap > _tempoGapLimit) return 4;
  var bars = switch (keyRel) {
    _KeyRel.same => 32,
    _KeyRel.relative => 8,
    _KeyRel.adjacent => 8,
    _KeyRel.energy => 4,
    _KeyRel.far => 4,
    _KeyRel.unknown => 8,
  };
  // Same key but drifting grids: a full 32 bars would flam.
  if (keyRel == _KeyRel.same &&
      tempoGap != null &&
      tempoGap > 0.02) {
    bars = 16;
  }
  // Room check: A must hold the window plus a breath; B needs the
  // window plus intro headroom for the mix-in scan to skip.
  if (bpmA != null && bpmA > 0) {
    for (final b in [32, 16, 8, 4]) {
      if (b > bars) continue;
      final d = b * 4 * 60.0 / bpmA;
      if (durA >= d + 1.0 && durB >= d + 12.0) return b;
    }
    return 4;
  }
  return bars;
}

_KeyRel _camelotRelation(String? a, String? b) {
  final pa = _parseOpen(a);
  final pb = _parseOpen(b);
  if (pa == null || pb == null) return _KeyRel.unknown;
  // Same code = identical key. Number AND ring must match.
  if (pa.$1 == pb.$1 && pa.$2 == pb.$2) return _KeyRel.same;
  // Same number, opposite ring: relative major/minor. Always legal.
  if (pa.$1 == pb.$1) return _KeyRel.relative;
  // One step around the wheel (wrapping 12 -> 1).
  final d = _wheelDistance(pa.$1, pb.$1);
  if (d == 1) return _KeyRel.adjacent;
  if (d == 2) return _KeyRel.energy;
  return _KeyRel.far;
}

/// Circular distance on the 12-position wheel.
int _wheelDistance(int a, int b) {
  final raw = (a - b).abs() % 12;
  return raw > 6 ? 12 - raw : raw;
}

/// '8m' -> (8, true). Null when it isn't a Camelot code.
(int, bool)? _parseOpen(String? open) {
  if (open == null || open.isEmpty) return null;
  final m = RegExp(r'^(\d{1,2})\s*([md])$', caseSensitive: false)
      .firstMatch(open.trim());
  if (m == null) return null;
  final num = int.tryParse(m.group(1)!);
  if (num == null || num < 1 || num > 12) return null;
  return (num, m.group(2)!.toLowerCase() == 'm');
}

double? _tempoGap(double? a, double? b) {
  if (a == null || b == null || a <= 0 || b <= 0) return null;
  // Half/double time reads as the same groove; compare both.
  var best = (a - b).abs() / math.max(a, b);
  for (final mult in [2.0, 0.5]) {
    final alt = (a * mult - b).abs() / math.max(a * mult, b);
    if (alt < best) best = alt;
  }
  return best;
}

/// Equal-power gains for a 0..1 progress: outgoing falls, incoming
/// rises, and the power sum stays flat so the blend never dips in the
/// middle (the classic linear-fade hole).
({double out, double in_}) crossfadeGains(double t) {
  final clamped = t.clamp(0.0, 1.0);
  final angle = clamped * math.pi / 2.0;
  return (out: math.cos(angle), in_: math.sin(angle));
}
