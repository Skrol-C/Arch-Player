import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/automix_pcm.dart';

/// Late drums: 30s of silence, then 24s of 120 BPM clicks.
/// The first window must abstain; a later window must win; the phase
/// must map back to track time (first click at 30.17s).
Uint8List _lateDrums() {
  final pcm = <int>[];
  for (var i = 0; i < 11025 * 54; i++) {
    final time = i / 11025.0;
    var value = 0.0;
    if (time >= 30.0) {
      final since = (time - 30.17) % 0.5;
      final transient = math.exp(-since * 50.0);
      value = 0.75 *
          transient *
          math.sin(time * 2.0 * math.pi * 100.0);
    }
    final s = (value * 32767.0).round().clamp(-32768, 32767);
    pcm
      ..add(s & 0xFF)
      ..add((s >> 8) & 0xFF);
  }
  return Uint8List.fromList(pcm);
}

void main() {
  test('late drums win a later window with grid-aligned phase', () async {
    final won = await analyzeTempoWindows(_lateDrums());
    expect(won.of, 3);
    expect(won.window, isNot(0));
    expect(won.grid.bpm, closeTo(120.0, 0.5));
    expect(won.grid.confidence, greaterThanOrEqualTo(0.55));
    // Phase is a grid alignment in track time: congruent to the
    // click grid (first click at 30.17s, 0.5s period), not
    // necessarily the first click itself. Circular distance, since
    // Dart's % is floored.
    final gridOffset = (won.grid.phase - 30.17) % 0.5;
    expect(math.min(gridOffset, 0.5 - gridOffset), lessThan(0.05));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
