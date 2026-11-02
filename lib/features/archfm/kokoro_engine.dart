library;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/log.dart';
import 'kokoro_voices.dart';
import 'model_store.dart';

/// Dart wrapper over the sherpa-onnx Kokoro engine. One instance
/// per process (the model is 330 MB resident): create with
/// `ensure`, render with `synthesize`, release with `dispose`.
/// Never throws. Null means render that break silent, never stall.

class KokoroEngine {
  static final KokoroEngine instance = KokoroEngine._();

  KokoroEngine._();

  sherpa.OfflineTts? _tts;
  bool _bindings = false;

  bool get loaded => _tts != null;

  /// Load the model from [ModelStore]. False when files are
  /// missing or init fails.
  Future<bool> ensure() async {
    if (_tts != null) return true;
    final dir = await ModelStore.modelDir();
    if (!await ModelStore.isInstalled()) {
      ArchLog.i('archfm', 'engine ensure: model not installed');
      return false;
    }
    try {
      if (!_bindings) {
        sherpa.initBindings();
        _bindings = true;
      }
      final tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: '${dir.path}/model.onnx',
              voices: '${dir.path}/voices.bin',
              tokens: '${dir.path}/tokens.txt',
              lexicon:
                  '${dir.path}/lexicon-us-en.txt,'
                  '${dir.path}/lexicon-custom.txt',
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        ),
      );
      _tts = tts;
      ArchLog.i('archfm', 'engine loaded from ${dir.path}');
      return true;
    } catch (e) {
      ArchLog.w('archfm', 'engine init failed: $e');
      return false;
    }
  }

  /// Render [text] to a wav at [outPath]. True on a written file.
  Future<bool> synthesize({
    required String text,
    required KokoroVoice voice,
    required double speed,
    required String outPath,
  }) async {
    final line = text.trim();
    if (line.isEmpty) return false;
    if (!await ensure()) return false;
    try {
      final audio = _tts!.generate(
        text: line,
        sid: voice.sid,
        speed: speed,
      );
      if (audio.samples.isEmpty) return false;
      sherpa.writeWave(
        filename: outPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      return true;
    } catch (e) {
      ArchLog.w('archfm', 'synthesize failed: $e');
      return false;
    }
  }

  void dispose() {
    try {
      _tts?.free();
    } catch (_) {}
    _tts = null;
  }
}
