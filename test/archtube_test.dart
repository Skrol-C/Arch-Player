import 'package:arch_player/features/archtube/archtube_client.dart';
import 'package:arch_player/features/archtube/client_identities.dart';
import 'package:arch_player/features/archtube/video_match.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('disguise ladder', () {
    test('ANDROID first, four identities, client context present', () {
      expect(archtubeLadder.length, 4);
      expect(archtubeLadder.first.clientName, 'ANDROID');
      expect(
        archtubeLadder.map((e) => e.clientName),
        ['ANDROID', 'iOS', 'ANDROID_VR', 'MWEB'],
      );
      final ctx = archtubeLadder.first.contextPayload();
      expect(ctx['client']['clientName'], 'ANDROID');
      expect(ctx['client']['hl'], 'en');
    });
  });

  group('parseProgressiveStreams', () {
    test('prefers itag 22, skips ciphered, keeps direct urls', () {
      final json = {
        'playabilityStatus': {'status': 'OK'},
        'streamingData': {
          'formats': [
            {
              'itag': 18,
              'url': 'https://example/18.mp4',
              'mime': 'video/mp4',
              'qualityLabel': '360p',
              'bitrate': 1,
            },
            {'itag': 999, 'signatureCipher': 's=abc&url=...'},
            {
              'itag': 22,
              'url': 'https://example/22.mp4',
              'mime': 'video/mp4',
              'qualityLabel': '720p',
              'bitrate': 2,
            },
          ],
        },
      };
      final streams = ArchtubeClient.parseProgressiveStreams(json);
      expect(streams.length, 2);
      expect(streams.first.itag, 22);
      expect(streams.last.itag, 18);
    });

    test('dry response yields empty (rotate signal)', () {
      expect(
        ArchtubeClient.parseProgressiveStreams({
          'playabilityStatus': {'status': 'OK'},
          'streamingData': {
            'formats': [
              {'itag': 999, 'signatureCipher': 's=abc'},
            ],
          },
        }),
        isEmpty,
      );
      expect(ArchtubeClient.parseProgressiveStreams({}), isEmpty);
    });
  });

  group('parseDurationLabel', () {
    test('M:SS and H:MM:SS', () {
      expect(ArchtubeClient.parseDurationLabel('3:45'), 225);
      expect(ArchtubeClient.parseDurationLabel('1:02:03'), 3723);
    });
    test('empty and LIVE are null', () {
      expect(ArchtubeClient.parseDurationLabel(''), isNull);
      expect(ArchtubeClient.parseDurationLabel('LIVE'), isNull);
    });
  });

  group('parseSearchHits', () {
    test('reads compact and full renderers, skips junk', () {
      final json = {
        'contents': {
          'sectionListRenderer': {
            'contents': [
              {
                'itemSectionRenderer': {
                  'contents': [
                    {
                      'compactVideoRenderer': {
                        'videoId': 'aaa111bbb22',
                        'title': {
                          'runs': [
                            {'text': 'Song Official Music Video'},
                          ],
                        },
                        'shortBylineText': {
                          'runs': [
                            {'text': 'Artist'},
                          ],
                        },
                        'lengthText': {'simpleText': '3:30'},
                      },
                    },
                    {
                      'videoRenderer': {
                        'videoId': 'ccc333ddd44',
                        'title': {'simpleText': 'Song live'},
                        'lengthText': {'simpleText': '4:05'},
                      },
                    },
                    {'chipCloudRenderer': {}},
                  ],
                },
              },
            ],
          },
        },
      };
      final hits = ArchtubeClient.parseSearchHits(json);
      expect(hits.length, 2);
      expect(hits.first.videoId, 'aaa111bbb22');
      expect(hits.first.title, 'Song Official Music Video');
      expect(hits.first.durationSecs, 210);
      expect(hits.last.videoId, 'ccc333ddd44');
    });
  });

  group('pickMatch', () {
    ArchtubeHit hit(String id, String title, int? secs) =>
        ArchtubeHit(videoId: id, title: title, channel: 'A',
            durationSecs: secs);

    test('bias to same song in a longer video', () {
      final won = pickMatch(
        hits: [
          hit('shortone111', 'Song', 195),
          hit('longone2222', 'Song Official Music Video', 208),
        ],
        songSecs: 200,
      );
      expect(won?.videoId, 'longone2222');
    });

    test('window excludes far cuts, null durations skipped', () {
      expect(
        pickMatch(
          hits: [
            hit('farfarfar11', 'Song extended set', 900),
            hit('nodurnone11', 'Song', null),
          ],
          songSecs: 200,
        ),
        isNull,
      );
    });

    test('empty hits is null', () {
      expect(pickMatch(hits: [], songSecs: 200), isNull);
    });
  });

  group('extractVideoId', () {
    test('bare id and url forms', () {
      expect(extractVideoId('aqz-KE-bpKQ'), 'aqz-KE-bpKQ');
      expect(
        extractVideoId('https://www.youtube.com/watch?v=aqz-KE-bpKQ'),
        'aqz-KE-bpKQ',
      );
      expect(extractVideoId('https://youtu.be/aqz-KE-bpKQ'),
          'aqz-KE-bpKQ');
      expect(
        extractVideoId('https://www.youtube.com/shorts/aqz-KE-bpKQ'),
        'aqz-KE-bpKQ',
      );
      expect(
        extractVideoId('https://www.youtube.com/embed/aqz-KE-bpKQ'),
        'aqz-KE-bpKQ',
      );
    });
    test('garbage is null', () {
      expect(extractVideoId(''), isNull);
      expect(extractVideoId('not a link at all'), isNull);
    });
  });

  group('VideoLink', () {
    test('encode/decode roundtrip with offset', () {
      const link = VideoLink(videoId: 'aqz-KE-bpKQ',
          videoOffsetSec: 2.5);
      final back = VideoLink.decode(link.encode());
      expect(back?.videoId, 'aqz-KE-bpKQ');
      expect(back?.videoOffsetSec, 2.5);
    });
    test('decode tolerates bare id and garbage', () {
      expect(VideoLink.decode('aqz-KE-bpKQ')?.videoId,
          'aqz-KE-bpKQ');
      expect(VideoLink.decode(''), isNull);
    });
  });
}
