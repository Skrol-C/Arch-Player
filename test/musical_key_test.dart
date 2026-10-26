import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/automix/musical_key.dart';

/// Rendered triads: root + third + fifth + octave root, 8s each.
/// Exact names expected — a key detector that can't name clean
/// triads has no business near real music.
Uint8List _chord(List<double> freqs) {
  final pcm = <int>[];
  for (var i = 0; i < 11025 * 8; i++) {
    final time = i / 11025.0;
    final amps = [0.5, 0.42, 0.46, 0.25];
    var value = 0.0;
    for (var k = 0; k < freqs.length; k++) {
      value += amps[k] * math.sin(time * 2.0 * math.pi * freqs[k]);
    }
    value /= 4;
    final s = (value * 32767.0).round().clamp(-32768, 32767);
    pcm
      ..add(s & 0xFF)
      ..add((s >> 8) & 0xFF);
  }
  return Uint8List.fromList(pcm);
}

void main() {
  test('names clean triads', () {
    final cases = [
      ([261.63, 329.63, 392.00, 523.25], 'C', '8d'), // C major
      ([220.00, 261.63, 329.63, 440.00], 'Am', '8m'), // A minor
      ([196.00, 246.94, 293.66, 392.00], 'G', '9d'), // G major
      ([185.00, 220.00, 277.18, 369.99], 'F#m', '11m'), // F# minor
      ([116.54, 146.83, 174.61, 233.08], 'A#', '6d'), // Bb major
    ];
    for (final (freqs, name, open) in cases) {
      final verdict = detectMusicalKey(_chord(freqs));
      final key = verdict.key;
      expect(key, isNotNull, reason: 'no key for $name');
      expect(key!.name, name);
      expect(key.openKey, open);
    }
  });

  test('silence is unknown', () {
    expect(detectMusicalKey(Uint8List(11025 * 8 * 2)).key, isNull);
    expect(detectMusicalKey(Uint8List(100)).key, isNull);
  });

  test('misses carry their evidence', () {
    final verdict = detectMusicalKey(Uint8List(11025 * 8 * 2));
    expect(verdict.key, isNull);
    expect(verdict.bestR, lessThan(0.6));
    expect(verdict.best, isEmpty);
  });

  test('relative pairs share every pitch class', () {
    expect(isRelativePair(9, false, 6, true), isTrue); // A <-> F#m
    expect(isRelativePair(5, false, 2, true), isTrue); // F <-> Dm
    expect(isRelativePair(6, true, 9, false), isTrue); // order-free
    expect(isRelativePair(2, true, 9, true), isFalse); // Dm vs Am
    expect(isRelativePair(5, true, 5, false), isFalse); // Fm vs F
    expect(isRelativePair(0, false, 7, false), isFalse); // C vs G
  });

  test('normalizes key names', () {
    expect(normalizeKeyName('Am'), (name: 'Am', openKey: '8m'));
    expect(normalizeKeyName('A minor'), (name: 'Am', openKey: '8m'));
    expect(normalizeKeyName('Bbm'), (name: 'A#m', openKey: '3m'));
    expect(normalizeKeyName('Bb'), (name: 'A#', openKey: '6d'));
    expect(normalizeKeyName('F#'), (name: 'F#', openKey: '2d'));
    expect(normalizeKeyName('8A'), (name: 'Am', openKey: '8m'));
    expect(normalizeKeyName('11B'), (name: 'A', openKey: '11d'));
    expect(normalizeKeyName(''), (name: '', openKey: ''));
    expect(normalizeKeyName('nonsense!!'), (name: '', openKey: ''));
  });
}
