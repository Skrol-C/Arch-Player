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
    this.bars = 8,
  });
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

  const BlendPlan({
    required this.filter,
    required this.seconds,
    required this.entryDelay,
    required this.startB,
    required this.tempoRatio,
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
  if (s.durA < overlap + 1.0) return null;

  // B enters on its first grid beat at/after first sound. Unknown
  // geometry starts at zero — degraded, never invented.
  final phaseB = s.phaseB ?? 0.0;
  final firstB = s.firstSoundB ?? 0.0;
  final j0 = math.max(0, ((firstB - phaseB) / periodB).ceil());
  final startB = phaseB + j0 * periodB;

  // A beats in file time: file t maps to A time (durA - overlap + t).
  // B's entry beat lands on the first A beat: delay < one period.
  final phaseA = s.phaseA ?? 0.0;
  final aOffset = s.durA - overlap;
  final entryDelay = ((phaseA - aOffset) % periodA + periodA) % periodA;

  // B must cover the file from its entry to the end, in input time
  // (atempo R speeds B up: input duration = output * R).
  final needInputB = (overlap - entryDelay) * ratio;
  if (startB + needInputB > s.durB - 0.5) return null;

  final d = overlap.toStringAsFixed(3);
  final ta = aOffset.toStringAsFixed(3);
  final tb = startB.toStringAsFixed(3);
  final tbDur = needInputB.toStringAsFixed(3);
  final delayMs = (entryDelay * 1000).round();
  final r = ratio.toStringAsFixed(6);
  final filter = '[0:a]aresample=44100,aformat=channel_layouts=stereo,'
      'atrim=start=$ta:duration=$d,asetpts=PTS-STARTPTS,'
      'highpass=f=120,'
      "volume='cos(PI/2*t/$d)':eval=frame[a];"
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
  );
}

/// Render the bridge to an AAC file. Returns the path, or null when
/// the pair can't be bridged or the render fails — never throws, so
/// the lab trigger can stay fire-and-forget.
Future<String?> renderBlend(BlendSpec spec, {String? tag}) async {
  try {
    final plan = buildBlend(spec);
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
      'entry=${plan.entryDelay.toStringAsFixed(3)}s '
      'ratio=${plan.tempoRatio.toStringAsFixed(4)} -> $out',
    );
    return out;
  } catch (e) {
    ArchLog.w('automix', 'blend render error: $e');
    return null;
  }
}
