library;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import 'kokoro_engine.dart';
import 'kokoro_voices.dart';
import 'model_store.dart';

/// ArchFM settings: persisted quiet notifiers in the automix
/// pattern (build syncs from disk, setters write through, log).
/// Defaults keep the station off and Bella on the mic.

final archFmEnabledProvider =
    NotifierProvider<ArchFmEnabledNotifier, bool>(ArchFmEnabledNotifier.new);

class ArchFmEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    _sync();
    return false;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('arch.archfm.enabled') ?? false;
  }

  Future<void> toggle() async {
    final v = !state;
    state = v;
    (await SharedPreferences.getInstance())
        .setBool('arch.archfm.enabled', v);
    ArchLog.i('archfm', 'enabled=$v');
  }
}

final archFmVoiceProvider =
    NotifierProvider<ArchFmVoiceNotifier, KokoroVoice>(
      ArchFmVoiceNotifier.new,
    );

class ArchFmVoiceNotifier extends Notifier<KokoroVoice> {
  @override
  KokoroVoice build() {
    _sync();
    return KokoroVoice.bella;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = KokoroVoice.fromName(prefs.getString('arch.archfm.voice'));
  }

  Future<void> setVoice(KokoroVoice v) async {
    state = v;
    (await SharedPreferences.getInstance())
        .setString('arch.archfm.voice', v.name);
    ArchLog.i('archfm', 'voice=${v.name}');
  }
}

final archFmPresetProvider =
    NotifierProvider<ArchFmPresetNotifier, FmPreset>(ArchFmPresetNotifier.new);

class ArchFmPresetNotifier extends Notifier<FmPreset> {
  @override
  FmPreset build() {
    _sync();
    return FmPreset.clean;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = FmPreset.fromName(prefs.getString('arch.archfm.preset'));
  }

  Future<void> setPreset(FmPreset v) async {
    state = v;
    (await SharedPreferences.getInstance())
        .setString('arch.archfm.preset', v.name);
    ArchLog.i('archfm', 'preset=${v.name}');
  }
}

/// Break every N songs. 2 is chatty, 5 is sparse, 3 is the house default.
final archFmFrequencyProvider =
    NotifierProvider<ArchFmFrequencyNotifier, int>(ArchFmFrequencyNotifier.new);

class ArchFmFrequencyNotifier extends Notifier<int> {
  static const options = [2, 3, 5];

  @override
  int build() {
    _sync();
    return 3;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt('arch.archfm.frequency') ?? 3;
    state = options.contains(v) ? v : 3;
  }

  Future<void> cycle() async {
    final next = options[(options.indexOf(state) + 1) % options.length];
    state = next;
    (await SharedPreferences.getInstance())
        .setInt('arch.archfm.frequency', next);
    ArchLog.i('archfm', 'frequency=$next');
  }
}

/// Static and crackle bed level, 0 to 1. Survives as a double so a
/// future slider maps without a migration.
final archFmStaticProvider =
    NotifierProvider<ArchFmStaticNotifier, double>(ArchFmStaticNotifier.new);

class ArchFmStaticNotifier extends Notifier<double> {
  static const options = [0.25, 0.5, 0.8];

  @override
  double build() {
    _sync();
    return 0.5;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble('arch.archfm.static') ?? 0.5;
    state = options.contains(v) ? v : 0.5;
  }

  String get label => state <= 0.25
      ? 'Low'
      : state >= 0.8
      ? 'High'
      : 'Medium';

  Future<void> cycle() async {
    final next = options[(options.indexOf(state) + 1) % options.length];
    state = next;
    (await SharedPreferences.getInstance()).setDouble('arch.archfm.static', next);
    ArchLog.i('archfm', 'static=$next');
  }
}

/// Duo handoffs stay parked for v1: the toggle exists so the Hub
/// can say so honestly, and flips on when the renderer chains two
/// voices in one file.
final archFmDuoProvider = NotifierProvider<ArchFmDuoNotifier, bool>(
  ArchFmDuoNotifier.new,
);

class ArchFmDuoNotifier extends Notifier<bool> {
  @override
  bool build() {
    _sync();
    return false;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('arch.archfm.duo') ?? false;
  }

  Future<void> toggle() async {
    final v = !state;
    state = v;
    (await SharedPreferences.getInstance()).setBool('arch.archfm.duo', v);
    ArchLog.i('archfm', 'duo=$v');
  }
}

/// Voice engine install state. The model lives or dies on disk:
/// boot re-checks the files, no prefs flag to go stale.
enum EngineStatus { missing, downloading, extracting, ready, failed }

class EngineState {
  final EngineStatus status;
  final double progress;
  final String note;

  const EngineState({
    this.status = EngineStatus.missing,
    this.progress = 0,
    this.note = '',
  });

  EngineState copyWith({
    EngineStatus? status,
    double? progress,
    String? note,
  }) => EngineState(
    status: status ?? this.status,
    progress: progress ?? this.progress,
    note: note ?? this.note,
  );
}

final kokoroEngineProvider =
    NotifierProvider<KokoroEngineNotifier, EngineState>(
      KokoroEngineNotifier.new,
    );

class KokoroEngineNotifier extends Notifier<EngineState> {
  bool _cancel = false;

  @override
  EngineState build() {
    _refresh();
    return const EngineState();
  }

  Future<void> _refresh() async {
    final ok = await ModelStore.isInstalled();
    state = state.copyWith(
      status: ok ? EngineStatus.ready : EngineStatus.missing,
      progress: ok ? 1 : 0,
      note: ok ? 'Installed, Bella and Michael ready' : '',
    );
  }

  /// Download plus extract plus lexicons. Long and resumable only
  /// by retry: a cancel or failure deletes the partial and lands
  /// back on missing, never a half engine.
  Future<void> install() async {
    if (state.status == EngineStatus.downloading ||
        state.status == EngineStatus.extracting) {
      return;
    }
    _cancel = false;
    state = state.copyWith(
      status: EngineStatus.downloading,
      progress: 0,
      note: 'Downloading voice engine',
    );
    final ok = await ModelStore.download(
      onProgress: (p) {
        state = state.copyWith(progress: p);
      },
      isCancelled: () => _cancel,
    );
    if (_cancel) {
      ArchLog.i('archfm', 'engine install cancelled');
      _refresh();
      return;
    }
    if (!ok) {
      state = state.copyWith(
        status: EngineStatus.failed,
        note: 'Download failed, tap to retry',
      );
      return;
    }
    state = state.copyWith(
      status: EngineStatus.extracting,
      note: 'Unpacking voices',
    );
    final unpacked = await ModelStore.extract();
    final lexed = unpacked && await ModelStore.installLexicons();
    if (!lexed || !await ModelStore.isInstalled()) {
      state = state.copyWith(
        status: EngineStatus.failed,
        note: 'Unpack failed, tap to retry',
      );
      return;
    }
    ArchLog.i('archfm', 'engine installed');
    _refresh();
  }

  void cancel() {
    _cancel = true;
  }

  Future<void> remove() async {
    _cancel = true;
    KokoroEngine.instance.dispose();
    await ModelStore.remove();
    ArchLog.i('archfm', 'engine removed');
    _refresh();
  }
}
