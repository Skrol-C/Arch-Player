library;
/// Kokoro voices and render presets for ArchFM. Pure data, no
/// platform calls: the native engine behind the bridge fills in
/// later, but every template, pack, and setting reads these types
/// from day one so nothing renames when synthesis lands.

/// The two ArchFM hosts. Solo breaks alternate between them;
/// pinned liners force one voice for that break.
enum KokoroVoice {
  bella,
  michael;

  String get label => switch (this) {
    KokoroVoice.bella => 'Bella',
    KokoroVoice.michael => 'Michael',
  };

  /// Morning 5 to 11 skews Bella-led unless the BPM runs high.
  /// Late night skews Bella solo. Michael owns high-energy cuts.
  String get persona => switch (this) {
    KokoroVoice.bella => 'Smooth, warm, mornings and late nights',
    KokoroVoice.michael => 'Drive-time energy, high BPM cuts',
  };

  /// sherpa-onnx speaker id in kokoro-en-v0_19: 1 is af_bella,
  /// 6 is am_michael. Verified against the release voice table.
  int get sid => switch (this) {
    KokoroVoice.bella => 1,
    KokoroVoice.michael => 6,
  };

  static KokoroVoice fromName(String? name) => switch (name) {
    'michael' => KokoroVoice.michael,
    _ => KokoroVoice.bella,
  };
}

/// Render preset: speed plus the DSP the radio sound needs. The
/// radio filter (bandpass roughly 120Hz to 8kHz with light
/// compression) is what makes it read as FM, not the voice.
enum FmPreset {
  clean,
  classic,
  lateNight;

  String get label => switch (this) {
    FmPreset.clean => 'Clean',
    FmPreset.classic => 'Classic FM',
    FmPreset.lateNight => 'Late Night',
  };

  String get blurb => switch (this) {
    FmPreset.clean => 'Untouched voice over a low crackle bed',
    FmPreset.classic => 'Compressed and warm, period FM',
    FmPreset.lateNight => 'Slower, warmer, more room reverb',
  };

  /// Kokoro speed multiplier. Outside 0.8 to 1.2 the hosts start
  /// sounding drunk or rushed, so presets stay inside the lane.
  double get speed => switch (this) {
    FmPreset.clean => 1.0,
    FmPreset.classic => 1.02,
    FmPreset.lateNight => 0.92,
  };

  /// Pitch shift in semitones, applied after synth. Beyond plus or
  /// minus 2 Bella turns chipmunk and Michael turns robot.
  double get pitchSemitones => switch (this) {
    FmPreset.clean => 0.0,
    FmPreset.classic => -0.5,
    FmPreset.lateNight => -1.5,
  };

  /// 0 keeps the voice full-range, 1 is full telephone bandpass.
  double get radioFilter => switch (this) {
    FmPreset.clean => 0.25,
    FmPreset.classic => 0.8,
    FmPreset.lateNight => 0.6,
  };

  static FmPreset fromName(String? name) => switch (name) {
    'classic' => FmPreset.classic,
    'lateNight' => FmPreset.lateNight,
    _ => FmPreset.clean,
  };
}
