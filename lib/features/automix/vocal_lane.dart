// Automatic vocal lane, detection core: lead-forward sections from
// raw PCM. Classical DSP, no ML, no network — STFT, Fitzgerald HPSS
// split, vocal-band harmonic scoring. What it actually finds is
// *lead* energy (voice, soloing guitar, anyone out front); for blend
// purposes that's the right quantity, since a guitar solo stacked
// under a vocal clashes just as hard.
//
// Runs once per track in an isolate and caches (chunk 2 wires the
// cache + device verification). Thresholds below are starting points
// tuned on synthesis; device logs decide the final numbers.

import 'dart:math' as math;
import 'dart:typed_data';

/// Radix-2 FFT, in place. Forward transform; scale is irrelevant
/// (downstream only ever takes ratios).
void _fft(List<double> real, List<double> imag) {
  final n = real.length;
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    while ((j & bit) != 0) {
      j &= ~bit;
      bit >>= 1;
    }
    j |= bit;
    if (i < j) {
      final tr = real[i];
      real[i] = real[j];
      real[j] = tr;
      final ti = imag[i];
      imag[i] = imag[j];
      imag[j] = ti;
    }
  }
  var len = 2;
  while (len <= n) {
    final ang = 2.0 * math.pi / len;
    final wRe = math.cos(ang);
    final wIm = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var wr = 1.0;
      var wi = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final ur = real[i + k];
        final ui = imag[i + k];
        final vr =
            real[i + k + len ~/ 2] * wr - imag[i + k + len ~/ 2] * wi;
        final vi =
            real[i + k + len ~/ 2] * wi + imag[i + k + len ~/ 2] * wr;
        real[i + k] = ur + vr;
        imag[i + k] = ui + vi;
        real[i + k + len ~/ 2] = ur - vr;
        imag[i + k + len ~/ 2] = ui - vi;
        final nwr = wr * wRe - wi * wIm;
        wi = wr * wIm + wi * wRe;
        wr = nwr;
      }
    }
    len <<= 1;
  }
}

/// Magnitude spectrogram, Hann-windowed. 1024-sample frames at 11,025 Hz
/// give ~10.8 Hz bins; 512-sample hop gives ~21.5 fps. Returns
/// frames x 513 (bins 0..511).
List<List<double>> stftMagnitudes(Uint8List pcm) {
  const frame = 1024;
  const hop = 512;
  final n = pcm.length ~/ 2;
  final data = ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes);
  final window = List<double>.generate(
    frame,
    (i) => 0.5 - 0.5 * math.cos(2.0 * math.pi * i / frame),
  );
  final out = <List<double>>[];
  final real = List<double>.filled(frame, 0.0);
  final imag = List<double>.filled(frame, 0.0);
  for (var start = 0; start + frame <= n; start += hop) {
    for (var i = 0; i < frame; i++) {
      real[i] = data.getInt16((start + i) * 2, Endian.little) / 32768.0 *
          window[i];
      imag[i] = 0.0;
    }
    _fft(real, imag);
    out.add([
      for (var b = 0; b <= frame ~/ 2; b++)
        math.sqrt(real[b] * real[b] + imag[b] * imag[b]) / frame,
    ]);
  }
  return out;
}

double _median(List<double> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

/// Fitzgerald HPSS with soft masks: median along time keeps the
/// sustained (harmonic), median along frequency keeps the transient
/// (percussive). Returns both components (mask * magnitude).
({List<List<double>> harmonic, List<List<double>> percussive}) hpssSplit(
  List<List<double>> mag, {
  int timeWin = 15,
  int freqWin = 15,
}) {
  final frames = mag.length;
  if (frames == 0) return (harmonic: const [], percussive: const []);
  final bins = mag[0].length;
  final halfT = timeWin ~/ 2;
  final halfF = freqWin ~/ 2;
  final harmonic = List<List<double>>.generate(
    frames,
    (_) => List<double>.filled(bins, 0.0),
  );
  final percussive = List<List<double>>.generate(
    frames,
    (_) => List<double>.filled(bins, 0.0),
  );
  for (var f = 0; f < frames; f++) {
    for (var b = 0; b < bins; b++) {
      var mt = 0.0;
      {
        final vals = <double>[];
        for (var d = -halfT; d <= halfT; d++) {
          final ff = (f + d).clamp(0, frames - 1);
          vals.add(mag[ff][b]);
        }
        mt = _median(vals);
      }
      var mf = 0.0;
      {
        final vals = <double>[];
        for (var d = -halfF; d <= halfF; d++) {
          final bb = (b + d).clamp(0, bins - 1);
          vals.add(mag[f][bb]);
        }
        mf = _median(vals);
      }
      final denom = mt * mt + mf * mf + 1e-12;
      harmonic[f][b] = mt * mt / denom * mag[f][b];
      percussive[f][b] = mf * mf / denom * mag[f][b];
    }
  }
  return (harmonic: harmonic, percussive: percussive);
}

/// Lead-forward sections as (start, end) seconds. Scores each ~0.5s
/// block by harmonic energy share in the 1–4 kHz band, then applies
/// hysteresis (enter 0.5, exit 0.4) and merges gaps under 2s. Blips
/// under a second are dropped — a cough is not a verse. The 0.5
/// entry counts voiced rap (GME's spoken intro); scoreless audio
/// must stay silent, which the drums-only test guards.
List<(double, double)> vocalSections(
  Uint8List pcm, {
  double enter = 0.5,
  double exit = 0.4,
}) {
  const hop = 512;
  const sr = 11025.0;
  const fps = sr / hop;
  final mag = stftMagnitudes(pcm);
  if (mag.isEmpty) return const [];
  final comp = hpssSplit(mag);
  // 1-4 kHz at ~10.8 Hz bins.
  const lo = 93;
  const hi = 371;
  final perBlock = (0.5 * fps).round().clamp(1, 1 << 30);
  final out = <(double, double)>[];
  var openStart = -1.0;
  var block = 0;
  var gapRun = 0;
  void flush(double endSec) {
    if (openStart >= 0 && endSec - openStart >= 1.0) {
      out.add((openStart, endSec));
    }
    openStart = -1.0;
    gapRun = 0;
  }

  for (var f0 = 0; f0 < mag.length; f0 += perBlock, block++) {
    final f1 = math.min(f0 + perBlock, mag.length);
    var harm = 0.0;
    var total = 0.0;
    for (var f = f0; f < f1; f++) {
      for (var b = lo; b <= hi && b < mag[f].length; b++) {
        harm += comp.harmonic[f][b];
        total += mag[f][b];
      }
    }
    final score = total > 0 ? harm / total : 0.0;
    final t = f0 / fps;
    if (openStart < 0) {
      if (score >= enter) openStart = t;
    } else {
      if (score >= exit) {
        gapRun = 0;
      } else {
        gapRun++;
        // Gap tolerance: 2s of dip doesn't split a phrase.
        if (gapRun * perBlock / fps > 2.0) {
          flush(t - gapRun * perBlock / fps);
        }
      }
    }
  }
  flush(mag.length / fps);
  return out;
}
