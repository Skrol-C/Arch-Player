import 'package:flutter_test/flutter_test.dart';

import 'package:arch_player/features/metadata/metadata_service.dart';

void main() {
  test('watched key variants share one dsp invalidate bucket', () {
    final svc = MetadataService();
    // Library entry: raw case + real path; search entry: other case,
    // unowned (empty path); queue entry: yet another spelling.
    svc.noteMusicalKey('Pink Floyd\x00Time\x00/storage/song.flac');
    svc.noteMusicalKey('pink floyd\x00TIME\x00');
    svc.noteMusicalKey('PINK FLOYD\x00Time\x00/other/path.mp3');
    final keys = svc.musicalKeysFor(artist: 'PINK FLOYD', title: 'time');
    expect(keys, hasLength(3));
    expect(keys, contains('Pink Floyd\x00Time\x00/storage/song.flac'));
    expect(keys, contains('pink floyd\x00TIME\x00'));
    svc.dispose();
  });

  test('unknown track resolves to no keys', () {
    final svc = MetadataService();
    expect(
      svc.musicalKeysFor(artist: 'Nobody', title: 'Nothing'),
      isEmpty,
    );
    svc.dispose();
  });

  test('empty artist/title never registers', () {
    final svc = MetadataService();
    svc.noteMusicalKey('\x00Title\x00/path');
    svc.noteMusicalKey('Artist\x00\x00/path');
    expect(svc.musicalKeysFor(artist: '', title: 'Title'), isEmpty);
    svc.dispose();
  });
}
