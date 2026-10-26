// Baked-blend prototype: render a transition offline with the FFmpeg
// we already ship, instead of performing it with two live players.
// v1 scope: fixed recipe (tempo-match + beat-align + bass swap),
// 8-bar default window, AAC bridge file played back as a preview.
// If the prototype blends, the pipeline (timing, skip mapping,
// failure fallbacks) gets built around it; if not, we iterate on
// the recipe here, never in the audio engine.
//
// Prototype pair: BLOODY STREAM (131.31, Cm) -> Give Me Everything
// (130.76, Cm). Same key, 0.4% tempo gap, both fully analyzed.

import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import 'automix_pcm.dart' show decodeMono11k;
import 'beat_grid.dart' show findMixIn, findMixOut;

/// Everything the renderer needs. Durations in seconds; phases and
/// first-sound in track time (the cached grid geometry). Null geometry
/// degrades to a zero-start, never to invented data.
class BlendSpec {
  final String aPath;
  final String bPath;
  final double durA;
  final double durB;
  final double bpmA;
  final double bpmB;
  final double? phaseA;
  final double? phaseB;
  final double? firstSoundB;

  /// Vocal sections in track time, both sides ([null] = unknown).
  /// Unknown A counts as always-vocal: the renderer protects the
  /// incoming vocal rather than gambling on an unanalyzed outro.
  final List<(double, double)>? vocalA;
  final List<(double, double)>? vocalB;

  /// A window ends here instead of at end-of-file (mix-out point).
  /// Null = file end. The caller falls back to the tail when the
  /// groove runs too close to the start to fit the window.
  final double? endA;
  final int bars;

  const BlendSpec({
    required this.aPath,
    required this.bPath,
    required this.durA,
    required this.durB,
    required this.bpmA,
    required this.bpmB,
    this.phaseA,
    this.phaseB,
    this.firstSoundB,
    this.vocalA,
    this.vocalB,
    this.endA,
    this.bars = 8,
  });
}

/// File-time intervals where BOTH tracks sing: the duck zones.
/// Unknown A vocals ([null]) counts as always-vocal — protect the
/// incoming vocal. Known-but-empty A means no clash. B windows map
/// through the atempo stretch + entry delay and clip to the bridge;
/// a B intro vocal that ends before the mix-in never enters at all.
List<(double, double)> vocalDuckWindows({
  required List<(double, double)>? vocalA,
  required List<(double, double)>? vocalB,
  required double aStart,
  required double bStart,
  required double delay,
  required double rate,
  required double length,
}) {
  if (vocalB == null || vocalB.isEmpty) return const [];
  final out = <(double, double)>[];
  final aWins = vocalA ?? const [(0.0, double.infinity)];
  for (final b in vocalB) {
    var bs = delay + (b.$1 - bStart) / rate;
    var be = delay + (b.$2 - bStart) / rate;
    if (be <= 0 || bs >= length) continue;
    bs = bs.clamp(0.0, length);
    be = be.clamp(0.0, length);
    for (final a in aWins) {
      final s = math.max(bs, a.$1 - aStart);
      final e = math.min(be, a.$2 - aStart);
      if (e > s) out.add((s, e));
    }
  }
  out.sort((x, y) => x.$1.compareTo(y.$1));
  return out;
}

/// Vocal talk trim: if lead vocals start in the last stretch AND run
/// past the last groove beat (talking over dead air or a faded bed),
/// end the bridge where the talking starts instead of fading under it.
/// Mid-song vocals don't qualify — only outros that outlive the drums.
/// Returns the (possibly unchanged) groove end.
double vocalTalkCut({
  required double grooveEnd,
  required double durA,
  required List<(double, double)>? vocalA,
  required double minEnd,
}) {
  if (vocalA == null || vocalA.isEmpty) return grooveEnd;
  for (final v in vocalA) {
    if (v.$1 > grooveEnd - 30.0 && v.$2 > grooveEnd + 0.5 && v.$1 >= minEnd) {
      return v.$1;
    }
  }
  return grooveEnd;
}

/// Best bridge for the pair: try the requested length first, then step
/// [16, 8, 4] while vocal clash covers more than a quarter of the
/// window. Unbridgeable at every length returns null (honest no-build).
/// Gating applies only when both sides' vocals are known — unanalyzed
/// tracks keep today's behavior instead of being punished for it.
BlendPlan? buildBestBlend(BlendSpec base) {
  final tried = <int>[];
  for (final b in [base.bars, 16, 8, 4]) {
    if (tried.contains(b)) continue;
    tried.add(b);
    final plan = buildBlend(
      BlendSpec(
        aPath: base.aPath,
        bPath: base.bPath,
        durA: base.durA,
        durB: base.durB,
        bpmA: base.bpmA,
        bpmB: base.bpmB,
        phaseA: base.phaseA,
        phaseB: base.phaseB,
        firstSoundB: base.firstSoundB,
        vocalA: base.vocalA,
        vocalB: base.vocalB,
        endA: base.endA,
        bars: b,
      ),
    );
    if (plan == null) continue;
    // Clash fraction of the window under vocal ducking.
    var clash = 0.0;
    for (final w in plan.ducks) {
      clash += w.$2 - w.$1;
    }
    clash = plan.seconds > 0 ? clash / plan.seconds : 0.0;
    final known = base.vocalA != null && base.vocalB != null;
    if (!known || clash <= 0.25) return plan;
  }
  return null;
}

/// One rendered bridge: the filter graph plus the geometry that built
/// it, so logs and tests can verify alignment without rendering.
class BlendPlan {
  /// Full -filter_complex string.
  final String filter;

  /// Bridge length in seconds (the overlap window).
  final double seconds;

  /// B entry delay in the file (lands on an A beat, < one period).
  final double entryDelay;

  /// B trim start in B track time (a grid beat >= first sound).
  final double startB;

  /// atempo factor applied to B (A's tempo / B's tempo).
  final double tempoRatio;

  /// Vocal-duck windows applied (file-time [start, end]).
  final List<(double, double)> ducks;

  /// Bar count that survived vocal gating (<= requested).
  final int bars;

  const BlendPlan({
    required this.filter,
    required this.seconds,
    required this.entryDelay,
    required this.startB,
    required this.tempoRatio,
    this.ducks = const [],
    this.bars = 8,
  });
}

/// Pure alignment + graph construction. Null when the pair can't be
/// bridged (missing tempo, absurd ratio, track shorter than the
/// window) — the caller falls back to the live crossfade.
BlendPlan? buildBlend(BlendSpec s) {
  if (s.bpmA <= 0 || s.bpmB <= 0) return null;
  if (s.durA <= 0 || s.durB <= 0) return null;
  final ratio = s.bpmA / s.bpmB;
  // atempo lane: gentle correction only. Anything bigger is a
  // different track, not a blend.
  if (ratio < 0.94 || ratio > 1.06) return null;
  final periodA = 60.0 / s.bpmA;
  final periodB = 60.0 / s.bpmB;
  final overlap = s.bars * 4 * periodA;
  // A window ends at the mix-out point (or file end): the bridge
  // covers [aEnd - overlap, aEnd] so the exit lands on groove.
  final aEnd = s.endA ?? s.durA;
  if (aEnd <= 0 || aEnd > s.durA) return null;
  if (aEnd < overlap + 1.0) return null;

  // B enters on its first grid beat at/after first sound. Unknown
  // geometry starts at zero — degraded, never invented. Callers pass
  // the mix-in scan (first groove beat) as firstSoundB when they have
  // audio; the raw first-sound otherwise.
  final phaseB = s.phaseB ?? 0.0;
  final firstB = s.firstSoundB ?? 0.0;
  final j0 = math.max(0, ((firstB - phaseB) / periodB).ceil());
  final startB = phaseB + j0 * periodB;

  // A beats in file time: file t maps to A time (aEnd - overlap + t).
  // B's entry beat lands on the first A beat: delay < one period.
  final phaseA = s.phaseA ?? 0.0;
  final aOffset = aEnd - overlap;
  final entryDelay = ((phaseA - aOffset) % periodA + periodA) % periodA;

  // B must cover the file from its entry to the end, in input time
  // (atempo R speeds B up: input duration = output * R).
  final needInputB = (overlap - entryDelay) * ratio;
  if (startB + needInputB > s.durB - 0.5) return null;

  // Vocal ducking: where BOTH tracks sing, A dips 6dB under B's vocal
  // (0.5s cosine-ish ramps). Unknown A counts as vocal — protect the
  // incoming vocal rather than gambling on an unanalyzed outro.
  final ducks = vocalDuckWindows(
    vocalA: s.vocalA,
    vocalB: s.vocalB,
    aStart: aOffset,
    bStart: startB,
    delay: entryDelay,
    rate: ratio,
    length: overlap,
  );
  final d = overlap.toStringAsFixed(3);
  // A exits over the last sixth of the bridge (v2's 65% dropped out
  // too early); B rises across the whole bridge. Equal-power shapes,
  // biased exit.
  final fadeA = (overlap * 0.85).toStringAsFixed(3);
  var aVol = 'cos(PI/2*min(t/$fadeA\\,1))';
  if (ducks.isNotEmpty) {
    final terms = ducks.map((w) {
      final rs = (w.$1 - 0.5).toStringAsFixed(3);
      final re = (w.$2 + 0.5).toStringAsFixed(3);
      return 'min(max((t-$rs)/0.5\\,0)\\,1)*min(max(($re-t)/0.5\\,0)\\,1)';
    }).join('+');
    aVol = '($aVol)*(1-0.5*($terms))';
  }
  final ta = aOffset.toStringAsFixed(3);
  final tb = startB.toStringAsFixed(3);
  final tbDur = needInputB.toStringAsFixed(3);
  final delayMs = (entryDelay * 1000).round();
  final r = ratio.toStringAsFixed(6);
  // A exits in the first two-thirds (the pile-up window is the tail);
  // B rises across the whole bridge. Equal-power shapes, biased exit.
  final filter = '[0:a]aresample=44100,aformat=channel_layouts=stereo,'
      'atrim=start=$ta:duration=$d,asetpts=PTS-STARTPTS,'
      'highpass=f=160:poles=2,'
      "volume='$aVol':eval=frame[a];"
      '[1:a]aresample=44100,aformat=channel_layouts=stereo,'
      'atrim=start=$tb:duration=$tbDur,asetpts=PTS-STARTPTS,'
      'atempo=$r,adelay=$delayMs|$delayMs,'
      "volume='sin(PI/2*t/$d)':eval=frame[b];"
      '[a][b]amix=inputs=2:duration=first:normalize=0[mix];'
      '[mix]alimiter=limit=0.95[out]';
  return BlendPlan(
    filter: filter,
    seconds: overlap,
    entryDelay: entryDelay,
    startB: startB,
    tempoRatio: ratio,
    ducks: ducks,
    bars: s.bars,
  );
}

/// Render the bridge to an AAC file. Returns the path, or null when
/// the pair can't be bridged or the render fails — never throws, so
/// the lab trigger can stay fire-and-forget.
Future<String?> renderBlend(BlendSpec spec, {String? tag}) async {
  try {
    // Mix-in scan: start B where the drums do, not where the file
    // makes its first sound. A 25s head is plenty — intros longer
    // than that are arrangements, not pickups. Then one bar deeper:
    // the first groove bar is often pickup, the blend wants the
    // settled groove.
    var firstB = spec.firstSoundB ?? 0.0;
    try {
      final head = await decodeMono11k(spec.bPath);
      if (head != null) {
        final groove = findMixIn(
          head,
          spec.bpmB,
          spec.phaseB ?? 0.0,
          firstB,
        );
        if (groove > firstB) {
          firstB = groove;
        }
        firstB += 4 * 60.0 / spec.bpmB;
        ArchLog.i(
          'automix',
          'blend mixin groove=${groove.toStringAsFixed(2)} '
          'start=${firstB.toStringAsFixed(2)}',
        );
      }
    } catch (_) {}
    // Mix-out scan: end A where the drums do, not at dead air.
    // Falls back to the tail when the groove runs too close to the
    // start to fit the window — an early groove plus a long tail
    // still beats a dropout. Then the vocal trim: outro talk that
    // outlives the groove gets cut instead of fading under B.
    var endA = spec.durA;
    try {
      final full = await decodeMono11k(spec.aPath, full: true);
      if (full != null) {
        final out = findMixOut(
          full,
          spec.bpmA,
          spec.phaseA ?? 0.0,
          spec.durA,
        );
        final earliest = spec.bars * 4 * 60.0 / spec.bpmA + 1.0;
        if (out < spec.durA - 0.5 && out >= earliest) {
          endA = out;
        }
        final talkCut = vocalTalkCut(
          grooveEnd: endA,
          durA: spec.durA,
          vocalA: spec.vocalA,
          minEnd: earliest,
        );
        if (talkCut < endA) {
          ArchLog.i(
            'automix',
            'blend mixout groove=${endA.toStringAsFixed(1)} '
            'talk=${talkCut.toStringAsFixed(1)}',
          );
          endA = talkCut;
        } else if (endA < spec.durA - 0.5) {
          ArchLog.i(
            'automix',
            'blend mixout tail=${spec.durA.toStringAsFixed(1)} '
            'groove=${endA.toStringAsFixed(1)}',
          );
        }
      }
    } catch (_) {}
    final plan = buildBestBlend(
      BlendSpec(
        aPath: spec.aPath,
        bPath: spec.bPath,
        durA: spec.durA,
        durB: spec.durB,
        bpmA: spec.bpmA,
        bpmB: spec.bpmB,
        phaseA: spec.phaseA,
        phaseB: spec.phaseB,
        firstSoundB: firstB,
        vocalA: spec.vocalA,
        vocalB: spec.vocalB,
        endA: endA,
        bars: spec.bars,
      ),
    );
    if (plan == null) {
      ArchLog.w('automix', 'blend unplannable (tempo/geometry/duration)');
      return null;
    }
    final dir = await getTemporaryDirectory();
    final out =
        '${dir.path}/blend_${tag ?? DateTime.now().millisecondsSinceEpoch}.m4a';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-v',
      'error',
      '-i',
      spec.aPath,
      '-i',
      spec.bPath,
      '-filter_complex',
      plan.filter,
      '-map',
      '[out]',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      out,
    ]).timeout(const Duration(seconds: 120));
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      ArchLog.w('automix', 'blend render failed rc=$code');
      return null;
    }
    final file = File(out);
    if (!await file.exists() || await file.length() == 0) {
      ArchLog.w('automix', 'blend render empty');
      return null;
    }
    ArchLog.i(
      'automix',
      'blend rendered ${plan.seconds.toStringAsFixed(1)}s '
      '(${plan.bars} bars) entry=${plan.entryDelay.toStringAsFixed(3)}s '
      'ratio=${plan.tempoRatio.toStringAsFixed(4)} '
      'ducks=${plan.ducks.length} -> $out',
    );
    return out;
  } catch (e) {
    ArchLog.w('automix', 'blend render error: $e');
    return null;
  }
}
