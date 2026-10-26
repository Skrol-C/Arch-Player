// Musical key from raw PCM: chromagram (Goertzel filterbank) +
// Krumhansl-Schmuckler major/minor profiles, answered as a canonical
// key name ("Am", "C") plus Traktor open key ("8m", "8d") for the
// harmonic ordering engine. Pure Dart, no deps — same discipline as
// the beat grid: bounded input, deterministic, tested on synthesis.

import 'dart:math' as math;
import 'dart:typed_data';

/// Detected key: canonical sharp name, Traktor open key, and the
/// evidence behind it ([strength] = winning Pearson r, [margin] =
/// gap to the runner-up).
class DetectedKey {
  final String name;
  final String openKey;
  final double strength;
  final double margin;

  const DetectedKey({
    required this.name,
    required this.openKey,
    required this.strength,
    required this.margin,
  });
}

/// Krumhansl-Schmuckler profiles, C-rooted.
const _ksMajor = [
  6.35,
  2.23,
  3.48,
  2.33,
  4.38,
  4.09,
  2.52,
  5.19,
  2.39,
  3.66,
  2.29,
  2.88,
];
const _ksMinor = [
  6.33,
  2.68,
  3.52,
  5.38,
  2.60,
  3.53,
  2.54,
  4.75,
  3.98,
  2.69,
  3.34,
  3.17,
];

const _sharpNames = [
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];

/// Camelot numbers by pitch class (C..B): major and minor.
const _camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1];
const _camelotMinor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10];

const _sampleRate = 11025.0;
const _frameSize = 4096;
const _frameHop = 2048;
const _midiLo = 36; // C2
const _midiHi = 83; // B5

/// Relative major/minor check: the minor tonic sits three semitones
/// below its major (A major <-> F# minor). Same pitch classes, so no
/// chroma detector can separate them — and the mixer treats them as
/// compatible — which is why the gate waives the margin for them.
bool isRelativePair(int tonicA, bool minorA, int tonicB, bool minorB) {
  if (minorA == minorB) return false;
  final major = minorA ? tonicB : tonicA;
  final minor = minorA ? tonicA : tonicB;
  return minor == (major + 9) % 12;
}

/// Verdict plus the evidence behind it, misses included: [bestR] is
/// the top profile correlation, [margin] its gap to runner-up, [best]
/// and [runner] their names. A miss with high bestR and a tiny margin
/// is an ambiguous track (often a relative major/minor tie), not a
/// deaf detector — the log line tells them apart.
({DetectedKey? key, double bestR, double margin, String best, String runner})
detectMusicalKey(Uint8List pcm) {
  ({DetectedKey? key, double bestR, double margin, String best, String runner})
  miss(double r, double m, String b, String rn) =>
      (key: null, bestR: r, margin: m, best: b, runner: rn);
  if (pcm.length < 2 * _frameSize) return miss(-2.0, 0.0, '', '');
  final n = pcm.length ~/ 2;
  final data = ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes);
  // Goertzel coefficients for every pitch, computed once.
  final midis = <int>[];
  final coeffs = <double>[];
  for (var m = _midiLo; m <= _midiHi; m++) {
    final f = 440.0 * math.pow(2.0, (m - 69) / 12.0);
    midis.add(m);
    coeffs.add(2.0 * math.cos(2.0 * math.pi * f / _sampleRate));
  }
  final chroma = List<double>.filled(12, 0.0);
  var frames = 0;
  for (var start = 0; start + _frameSize <= n; start += _frameHop) {
    frames++;
    for (var k = 0; k < midis.length; k++) {
      final coeff = coeffs[k];
      var s0 = 0.0, s1 = 0.0, s2 = 0.0;
      for (var i = 0; i < _frameSize; i++) {
        final v = data.getInt16((start + i) * 2, Endian.little) / 32768.0;
        s0 = v + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
      }
      final mag = math.sqrt(math.max(0.0, s1 * s1 + s2 * s2 - s1 * s2 * coeff));
      chroma[midis[k] % 12] += mag;
    }
  }
  if (frames == 0) return miss(-2.0, 0.0, '', '');
  for (var i = 0; i < 12; i++) {
    chroma[i] /= frames;
  }
  if (chroma.every((v) => v <= 0.0)) return miss(-2.0, 0.0, '', '');
  // Mean-center, then Pearson against every rotated profile.
  final mean = chroma.reduce((a, b) => a + b) / 12.0;
  final centered = [for (final v in chroma) v - mean];
  final norm = math.sqrt(centered.fold(0.0, (a, b) => a + b * b));
  if (norm <= 0.0) return miss(-2.0, 0.0, '', '');
  var best = '', bestOpen = '', runner = '', bestR = -2.0, runnerR = -2.0;
  var bestTonic = -1, bestMinor = false;
  var runnerTonic = -1, runnerMinor = false;
  for (var tonic = 0; tonic < 12; tonic++) {
    for (var minor = 0; minor < 2; minor++) {
      final base = minor == 1 ? _ksMinor : _ksMajor;
      final meanBase = base.reduce((a, b) => a + b) / 12.0;
      var dot = 0.0, baseNorm = 0.0;
      for (var i = 0; i < 12; i++) {
        final p = base[(i - tonic + 12) % 12] - meanBase;
        dot += centered[i] * p;
        baseNorm += p * p;
      }
      final r = dot / (norm * math.sqrt(baseNorm));
      final name = _sharpNames[tonic] + (minor == 1 ? 'm' : '');
      final num = (minor == 1 ? _camelotMinor : _camelotMajor)[tonic];
      final open = '$num${minor == 1 ? 'm' : 'd'}';
      if (r > bestR) {
        runnerR = bestR;
        runner = best;
        runnerTonic = bestTonic;
        runnerMinor = bestMinor;
        bestR = r;
        best = name;
        bestOpen = open;
        bestTonic = tonic;
        bestMinor = minor == 1;
      } else if (r > runnerR) {
        runnerR = r;
        runner = name;
        runnerTonic = tonic;
        runnerMinor = minor == 1;
      }
    }
  }
  // Gate: needs a real consensus, not a coin flip. Synthetic triads
  // score far above this; noise and silence never get here. One
  // exception: a relative major/minor tie shares every pitch class —
  // no chroma detector can separate them, and the mixer treats them
  // as compatible — so publish the winner instead of abstaining on
  // an undecidable coin flip.
  if (bestR < 0.6) return miss(bestR, bestR - runnerR, best, runner);
  if (bestR - runnerR < 0.03 &&
      !isRelativePair(bestTonic, bestMinor, runnerTonic, runnerMinor)) {
    return miss(bestR, bestR - runnerR, best, runner);
  }
  return (
    key: DetectedKey(
      name: best,
      openKey: bestOpen,
      strength: bestR,
      margin: bestR - runnerR,
    ),
    bestR: bestR,
    margin: bestR - runnerR,
    best: best,
    runner: runner,
  );
}

/// Tolerant key-name normalization for embedded tags and network
/// lanes: "Am", "A minor", "Bbm", "F#", Camelot "8A"/"11B" all land
/// on canonical (name, openKey). Unknown = ('', '').
({String name, String openKey}) normalizeKeyName(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return (name: '', openKey: '');
  final camel = RegExp(r'^(\d{1,2})\s*([ABab])$').firstMatch(s);
  if (camel != null) {
    final num = int.parse(camel.group(1)!);
    if (num < 1 || num > 12) return (name: '', openKey: '');
    final minor = camel.group(2)!.toUpperCase() == 'A';
    final table = minor ? _camelotMinor : _camelotMajor;
    final tonic = table.indexOf(num);
    if (tonic < 0) return (name: '', openKey: '');
    final name = _sharpNames[tonic] + (minor ? 'm' : '');
    return (name: name, openKey: '$num${minor ? 'm' : 'd'}');
  }
  final m = RegExp(r'^([A-Ga-g])([#♯b♭]{0,2})(.*)$').firstMatch(s);
  if (m == null) return (name: '', openKey: '');
  const base = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
  var pc = base[m.group(1)!.toUpperCase()]!;
  for (final c in m.group(2)!.split('')) {
    if (c == '#' || c == '♯') pc += 1;
    if (c == 'b' || c == '♭') pc -= 1;
  }
  pc = ((pc % 12) + 12) % 12;
  final suffix = m.group(3)!.trim().toLowerCase();
  final minor = suffix == 'm' || suffix.startsWith('min');
  final name = _sharpNames[pc] + (minor ? 'm' : '');
  final num = (minor ? _camelotMinor : _camelotMajor)[pc];
  return (name: name, openKey: '$num${minor ? 'm' : 'd'}');
}
