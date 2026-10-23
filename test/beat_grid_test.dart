// Bit-exactness tests for the Mornye beat-grid port: synthetic drum
// vectors with the original's expected outputs. Exact double
// equality on purpose — any drift means the port diverged.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/beat_grid.dart';

Uint8List _drums(double inputBpm, {double gainSlope = 0.0}) {
  final pcm = <int>[];
  for (var i = 0; i < 11025 * 24; i++) {
    final time = i / 11025.0;
    final since = (time - 0.17) % (60.0 / inputBpm);
    final transient = time < 0.17 ? 0.0 : math.exp(-since * 50.0);
    final gain = gainSlope == 0.0 ? 1.0 : 0.03 + 0.97 * math.pow(time / 24.0, 3);
    final value = 0.75 *
        gain *
        transient *
        math.sin(time * 2.0 * math.pi * 100.0);
    final s = (value * 32767.0).round();
    pcm
      ..add(s & 0xFF)
      ..add((s >> 8) & 0xFF);
  }
  return Uint8List.fromList(pcm);
}

void main() {
  test('matches shared drum vectors', () {
    final expected = [
      (90.0, 90.0, 0.16834467120181407, 0.8021635512174413),
      (120.0, 119.99, 0.16834467120181407, 0.9844533705342401),
      (124.0, 123.88, 0.156734693877551, 0.8467090068250587),
      (160.0, 160.15, 0.1799546485260771, 0.8319336271448226),
    ];
    for (final (inputBpm, bpm, phase, confidence) in expected) {
      final grid = analyzeAutomixPcm(_drums(inputBpm));
      expect(grid.bpm, bpm);
      expect(grid.phase, phase);
      expect((grid.confidence - confidence).abs() < 1e-12, isTrue);
      expect(grid.firstSound, 0.16253968253968254);
    }
  });

  test('keeps quiet beats in changing dynamics', () {
    for (final bpm in [90.0, 120.0, 124.0, 160.0]) {
      final grid = analyzeAutomixPcm(_drums(bpm, gainSlope: 1.0));
      expect(grid.confidence, greaterThanOrEqualTo(0.55));
      expect((grid.bpm - bpm).abs(), lessThan(0.4));
      expect(grid.firstSound, lessThan(0.3));
    }
  });

  test('noise does not invent a reliable beat', () {
    var seed = 11;
    final pcm = <int>[];
    for (var i = 0; i < 11025 * 24; i++) {
      seed = (seed ^ (seed << 13)) & 0xFFFFFFFF;
      seed = (seed ^ (seed >> 17)) & 0xFFFFFFFF;
      seed = (seed ^ (seed << 5)) & 0xFFFFFFFF;
      final s = seed & 0xFFFF;
      final signed = s >= 0x8000 ? s - 0x10000 : s;
      pcm
        ..add(signed & 0xFF)
        ..add((signed >> 8) & 0xFF);
    }
    final grid = analyzeAutomixPcm(Uint8List.fromList(pcm));
    expect(grid.confidence, lessThan(0.55));
  });

  test('silence, short and partial frames remain unknown', () {
    for (final size in [0, 11025 * 5 * 2, 11025 * 24 * 2 + 1]) {
      final grid = analyzeAutomixPcm(Uint8List(size));
      expect(grid.bpm, 0.0);
      expect(grid.confidence, 0.0);
    }
    expect(
      () => analyzeAutomixPcm(Uint8List(11025 * 2 * 25 + 1)),
      throwsArgumentError,
    );
  });
}
