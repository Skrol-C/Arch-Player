import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/vocal_lane.dart';

/// Mono 16-bit 11,025 Hz PCM from a sample function.
Uint8List _render(double seconds, double Function(double t) fn) {
  final n = (11025 * seconds).round();
  final pcm = <int>[];
  for (var i = 0; i < n; i++) {
    final s = (fn(i / 11025.0) * 32767.0).round().clamp(-32768, 32767);
    pcm
      ..add(s & 0xFF)
      ..add((s >> 8) & 0xFF);
  }
  return Uint8List.fromList(pcm);
}

double _argmaxBin(List<double> spectrum) {
  var best = 0;
  for (var i = 1; i < spectrum.length; i++) {
    if (spectrum[i] > spectrum[best]) best = i;
  }
  return best.toDouble();
}

void main() {
  test('fft peaks at the tone bin', () {
    // 440 Hz at ~10.8 Hz bins -> bin 41.
    final pcm = _render(1.0, (t) => 0.8 * math.sin(t * 2 * math.pi * 440.0));
    final mag = stftMagnitudes(pcm);
    expect(mag, isNotEmpty);
    expect(_argmaxBin(mag[mag.length ~/ 2]), closeTo(41, 1.5));
  });

  test('silence stays silent', () {
    final pcm = _render(1.0, (_) => 0.0);
    final mag = stftMagnitudes(pcm);
    var peak = 0.0;
    for (final frame in mag) {
      for (final v in frame) {
        peak = math.max(peak, v);
      }
    }
    expect(peak, lessThan(1e-9));
  });

  test('hpss splits sustained tones from transients', () {
    // 880 Hz bed throughout, 3 kHz pips every 0.5s.
    final pcm = _render(2.0, (t) {
      final bed = 0.4 * math.sin(t * 2 * math.pi * 880.0);
      final since = t % 0.5;
      final pip = since < 0.005
          ? 0.8 * math.sin(t * 2 * math.pi * 3000.0)
          : 0.0;
      return bed + pip;
    });
    final mag = stftMagnitudes(pcm);
    final comp = hpssSplit(mag);
    const fps = 11025.0 / 512;
    var percNear = 0.0, percTotal = 0.0, harmNear = 0.0, harmTotal = 0.0;
    for (var f = 0; f < mag.length; f++) {
      final t = f / fps;
      final nearClick = (t % 0.5) < 0.06 || (t % 0.5) > 0.44;
      for (var b = 0; b < mag[f].length; b++) {
        percTotal += comp.percussive[f][b];
        harmTotal += comp.harmonic[f][b];
        if (nearClick) {
          percNear += comp.percussive[f][b];
          harmNear += comp.harmonic[f][b];
        }
      }
    }
    // Transients concentrate in the percussive lane...
    expect(percNear / percTotal, greaterThan(0.5));
    // ...while the bed lives everywhere, not just at clicks.
    // (Uniform over time would read ~0.24 = the window fraction.)
    final harmShare = harmNear / harmTotal;
    expect(harmShare, greaterThan(0.15));
    expect(harmShare, lessThan(0.4));
  });

  test('sections find the verse, skip drums-only bars', () {
    // Clicks throughout; a harmonic-rich lead (220 Hz + harmonics,
    // voice-like) joins 2.0-5.0 with a 0.5s breather at 3.0 (gap merge
    // must hold the phrase together). A pure sine would sit below the
    // 1 kHz band edge and prove nothing.
    double lead(double t) {
      var v = 0.0;
      for (var k = 1; k <= 8; k++) {
        v += 0.5 / k * math.sin(t * 2 * math.pi * 220.0 * k);
      }
      return v;
    }

    final pcm = _render(8.0, (t) {
      // Clicks deliberately quieter than the lead: the test proves the
      // separation mechanism, not the threshold. Real verses are
      // voice-dominant; threshold calibration is device work.
      final sinceClick = t % 0.25;
      final click = sinceClick < 0.005
          ? 0.4 * math.sin(t * 2 * math.pi * 3000.0)
          : 0.0;
      final inVerse = (t >= 2.0 && t < 3.0) || (t >= 3.5 && t < 5.0);
      return click + (inVerse ? lead(t) : 0.0);
    });
    final sections = vocalSections(pcm);
    expect(sections, hasLength(1));
    expect(sections[0].$1, closeTo(2.0, 0.6));
    expect(sections[0].$2, closeTo(5.0, 0.6));
  });

  test('drums alone produce no sections', () {
    final pcm = _render(4.0, (t) {
      final sinceClick = t % 0.25;
      return sinceClick < 0.005
          ? 0.8 * math.sin(t * 2 * math.pi * 3000.0)
          : 0.0;
    });
    expect(vocalSections(pcm), isEmpty);
  });
}
