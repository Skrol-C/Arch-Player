import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/core/models.dart';
import 'package:arch_player/features/automix/harmonic_order.dart';

Song _song(int id) => Song(
  id: id,
  uri: Uri.parse('content://track/$id'),
  title: 'T$id',
  artist: 'A',
  album: 'AL',
  albumId: 1,
  duration: const Duration(minutes: 3),
  year: 2024,
  folderKey: 'f',
  folderLabel: 'F',
);

TrackMusicalInfo _info({double? bpm, String open = ''}) =>
    TrackMusicalInfo(bpm: bpm, openKey: open, source: 'test');

void main() {
  test('same key outranks relative outranks adjacent', () {
    expect(harmonicRelation('5m', '5m'), HarmonicRel.same);
    expect(harmonicRelation('5m', '5d'), HarmonicRel.relative);
    // 5 -> 6 is one wheel step.
    expect(harmonicRelation('5m', '6m'), HarmonicRel.adjacent);
    // 5 -> 7 is two steps: energy lift.
    expect(harmonicRelation('5m', '7m'), HarmonicRel.energy);
    // 5 -> 9 is far.
    expect(harmonicRelation('5m', '9m'), HarmonicRel.far);
    expect(harmonicRelation(null, '5m'), HarmonicRel.unknown);
    expect(harmonicRelation('bogus', '5m'), HarmonicRel.unknown);
  });

  test('tempo gap is octave-tolerant', () {
    expect(tempoGap(130.76, 131.31), lessThan(0.01));
    // Half counts as the same groove.
    expect(tempoGap(65.0, 130.0), lessThan(0.01));
    // Genuine clash stays large.
    expect(tempoGap(100.0, 150.0), greaterThan(0.2));
    expect(tempoGap(null, 120.0), isNull);
  });

  test('score prefers key, then tempo', () {
    const sameFar = 100.0;
    final same = harmonicScore(
      openA: '5m',
      openB: '5m',
      bpmA: 100.0,
      bpmB: 150.0,
    );
    final adjacentClose = harmonicScore(
      openA: '5m',
      openB: '6m',
      bpmA: 128.0,
      bpmB: 128.0,
    );
    // Same key with a tempo gap still beats adjacent-but-locked?
    // No: harmony leads but a 50% gap costs 40 points.
    expect(same, lessThan(sameFar));
    expect(adjacentClose, closeTo(70.0, 0.01));
    // Key-only info (no BPM) gets half credit, still orderable.
    expect(
      harmonicScore(openA: '5m', openB: '5m', bpmA: null, bpmB: null),
      50.0,
    );
  });

  test('batch walks the best next, skipping unknowns', () {
    // 1:Cm/130 2:Cm/131 3:Gm/140 4:unknown 5:Fm/90
    final songs = [_song(1), _song(2), _song(3), _song(4), _song(5)];
    final infos = {
      1: _info(bpm: 130.0, open: '5m'),
      2: _info(bpm: 131.0, open: '5m'),
      3: _info(bpm: 140.0, open: '7m'),
      4: _info(),
      5: _info(bpm: 90.0, open: '4m'),
    };
    final got = pickHarmonicBatch(
      songs: songs,
      infoOf: (s) => infos[s.id],
      fromId: 1,
      recentIds: const {},
      k: 3,
    );
    // Greedy walk: 2 (same key) first, then 5 beats 3 from 2's
    // doorstep. #4 is unknown and never picked.
    expect(got, [2, 5, 3]);
    expect(got, isNot(contains(4)));
  });

  test('recent tracks are avoided until the pool runs dry', () {
    final songs = [_song(1), _song(2), _song(3)];
    final infos = {
      1: _info(bpm: 120.0, open: '5m'),
      2: _info(bpm: 120.0, open: '5m'),
      3: _info(bpm: 120.0, open: '3m'),
    };
    // 2 is banned: 3 wins despite the worse key.
    expect(
      pickHarmonicBatch(
        songs: songs,
        infoOf: (s) => infos[s.id],
        fromId: 1,
        recentIds: {2},
        k: 1,
      ),
      [3],
    );
    // Everything banned or self: relax rather than stop.
    expect(
      pickHarmonicBatch(
        songs: songs,
        infoOf: (s) => infos[s.id],
        fromId: 1,
        recentIds: {2, 3},
        k: 2,
      ),
      isNotEmpty,
    );
  });

  test('empty library and unknown from-id stay silent', () {
    expect(
      pickHarmonicBatch(
        songs: const [],
        infoOf: (_) => null,
        fromId: 1,
        recentIds: const {},
        k: 5,
      ),
      isEmpty,
    );
    expect(
      pickHarmonicBatch(
        songs: [_song(1), _song(2)],
        infoOf: (_) => _info(),
        fromId: 9,
        recentIds: const {},
        k: 5,
      ),
      isEmpty,
    );
  });
}
