import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'beat_grid.dart';
import 'musical_key.dart';

/// Decode to mono 16-bit 11,025 Hz PCM. Clipped mode caps at 25s
/// (the beat grid's native window); full mode decodes up to 10
/// minutes for multi-window analysis and whole-track key.
/// Null when the file can't be decoded. Scratch lives in cache,
/// deleted right after analysis.
Future<Uint8List?> decodeMono11k(String path, {bool full = false}) async {
  try {
    if (path.isEmpty || !await File(path).exists()) return null;
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/automix_${path.hashCode}.pcm';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-v',
      'error',
      '-i',
      path,
      '-ac',
      '1',
      '-ar',
      '11025',
      '-f',
      's16le',
      '-t',
      full ? '600' : '25',
      out,
    ]).timeout(const Duration(seconds: 90));
    final code = await session.getReturnCode();
    try {
      if (!ReturnCode.isSuccess(code)) return null;
      final bytes = await File(out).readAsBytes();
      if (bytes.isEmpty) return null;
      return bytes;
    } finally {
      try {
        await File(out).delete();
      } catch (_) {}
    }
  } catch (_) {
    return null;
  }
}

/// Beat grid in an isolate; the engine thread never feels it.
Future<AutoMixBeatGrid> analyzeGrid(Uint8List bytes) =>
    compute(_analyzeGrid, bytes);

AutoMixBeatGrid _analyzeGrid(Uint8List bytes) => analyzeAutomixPcm(bytes);

/// Musical key in an isolate. Null = unknown (silence, no consensus).
Future<DetectedKey?> analyzeKey(Uint8List bytes) =>
    compute(_analyzeKey, bytes);

DetectedKey? _analyzeKey(Uint8List bytes) => detectMusicalKey(bytes);

/// Multi-window tempo: three 25s slices (start / 40% / 70%) analyzed
/// in parallel isolates, best confidence wins, middle preferred on
/// ties. Phase and first-sound map back to track time by adding the
/// winning window's offset. Short tracks (< ~27s) keep the single
/// start window. Returns the winner, its index, and the window
/// count for logging — the caller still applies the confidence gate.
Future<({AutoMixBeatGrid grid, int window, int of})> analyzeTempoWindows(
  Uint8List pcm,
) async {
  const windowBytes = 11025 * 2 * 25;
  const fractions = [0.0, 0.4, 0.7];
  final totalSec = pcm.length / (11025 * 2);
  final starts = totalSec < 27
      ? [0]
      : [
          for (final f in fractions)
            ((totalSec - 25.0) * f * 11025 * 2).round(),
        ];
  final slices = <Uint8List>[];
  for (final start in starts) {
    final end = (start + windowBytes).clamp(0, pcm.length);
    slices.add(
      Uint8List.sublistView(pcm, start, end),
    );
  }
  final grids = await Future.wait(slices.map(analyzeGrid));
  // Best confidence wins; exact ties prefer the middle window
  // (arrangement peaks mid-track, intros/outros lie).
  var best = 0;
  for (var i = 1; i < grids.length; i++) {
    if (grids[i].confidence > grids[best].confidence ||
        (grids[i].confidence == grids[best].confidence && i == 1)) {
      best = i;
    }
  }
  final offsetSec = starts[best] / (11025 * 2);
  final won = grids[best];
  return (
    grid: AutoMixBeatGrid(
      bpm: won.bpm,
      phase: won.phase + offsetSec,
      confidence: won.confidence,
      firstSound: won.firstSound + offsetSec,
    ),
    window: best,
    of: slices.length,
  );
}
