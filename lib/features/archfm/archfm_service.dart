library;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import 'kokoro_engine.dart';
import 'kokoro_voices.dart';
import 'liner_bank.dart';
import 'model_store.dart';

/// ArchFM service: liner picks plus the render path. Renders to
/// app files (never cache) and returns the wav path. Null means
/// skip the break that rotation, never stall the music.

class ArchFmService {
  KokoroVoice _lastVoice = KokoroVoice.michael;
  final Set<String> _recentIds = {};

  /// Resolve the next break: pick a liner, fill it from metadata,
  /// alternate the host. Pure except for the rotation memory.
  ({String text, KokoroVoice voice, LinerTemplate liner}) nextBreak({
    required DateTime now,
    double? bpm,
    String? artist,
    String? title,
    String? album,
    String? nextArtist,
    String? nextTitle,
    int? year,
    String? genre,
  }) {
    final pick = resolveLiner(
      now: now,
      bpm: bpm,
      lastVoice: _lastVoice,
      recentIds: _recentIds,
    )!;
    _lastVoice = pick.voice;
    _recentIds.add(pick.liner.id);
    while (_recentIds.length > 6) {
      _recentIds.remove(_recentIds.first);
    }
    final text = fillLiner(
      pick.liner.text,
      artist: artist,
      title: title,
      album: album,
      nextArtist: nextArtist,
      nextTitle: nextTitle,
      year: year,
      genre: genre,
      bpm: bpm,
    );
    return (text: text, voice: pick.voice, liner: pick.liner);
  }

  /// Render a liner to a wav. Null until the engine is installed.
  Future<String?> renderLiner({
    required String text,
    required KokoroVoice voice,
    required FmPreset preset,
  }) async {
    final engine = KokoroEngine.instance;
    if (!await engine.ensure()) {
      ArchLog.i('archfm', 'render skipped: engine not installed');
      return null;
    }
    final dir = await ModelStore.modelDir();
    final out =
        '${dir.path}/break_${DateTime.now().millisecondsSinceEpoch}.wav';
    final ok = await engine.synthesize(
      text: text,
      voice: voice,
      speed: preset.speed,
      outPath: out,
    );
    if (!ok) return null;
    // Static bed mix and radio filter ride ffmpeg here next.
    // Voice-only file is the milestone before that.
    return out;
  }

  /// Render [text] and play it once through a throwaway player.
  /// Fire-and-forget by design: failures log, never throw.
  Future<void> playSample({
    required String text,
    required KokoroVoice voice,
    required FmPreset preset,
  }) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final out =
          '${docs.path}/archfm/sample_${DateTime.now().millisecondsSinceEpoch}.wav';
      final ok = await KokoroEngine.instance.synthesize(
        text: text,
        voice: voice,
        speed: preset.speed,
        outPath: out,
      );
      if (!ok) return;
      final player = AudioPlayer();
      try {
        await player.setFilePath(out);
        await player.play();
        await player.processingStateStream.firstWhere(
          (s) => s == ProcessingState.completed,
        );
      } finally {
        await player.dispose();
      }
    } catch (e) {
      ArchLog.w('archfm', 'sample playback failed: $e');
    }
  }
}
