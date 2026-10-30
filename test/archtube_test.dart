import 'package:arch_player/features/archtube/archtube_client.dart';
import 'package:arch_player/features/archtube/client_identities.dart';
import 'package:arch_player/features/archtube/dash_proxy.dart';
import 'package:arch_player/features/archtube/player_js.dart';
import 'package:arch_player/features/archtube/po_token.dart';
import 'package:arch_player/features/archtube/upstream_engine.dart';
import 'package:arch_player/features/archtube/video_match.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

  group('parseAdaptiveStreams', () {
    Map<String, dynamic> dashJson(List<Map<String, dynamic>> formats) => {
          'streamingData': {'adaptiveFormats': formats},
        };
    Map<String, dynamic> v(int itag, String q, String mime, int h, int br,
            {String? url}) =>
        {
          'itag': itag,
          'url': url ?? 'https://example/$itag',
          'mimeType': mime,
          'qualityLabel': q,
          'width': 16,
          'height': h,
          'bitrate': br,
        };
    Map<String, dynamic> a(int itag, String mime, int br) => {
          'itag': itag,
          'url': 'https://example/$itag',
          'mimeType': mime,
          'bitrate': br,
        };

    test('mp4 ladder first, tallest first, ciphered skipped', () {
      final dash = ArchtubeClient.parseAdaptiveStreams(dashJson([
        v(303, '1080p60', 'video/webm; codecs="vp9"', 1080, 8000),
        v(299, '1080p60', 'video/mp4; codecs="avc1.64002A"', 1080, 6000),
        v(18, '360p', 'video/mp4; codecs="avc1.42001E"', 360, 1000),
        {'itag': 137, 'signatureCipher': 's=abc'},
        a(251, 'audio/webm; codecs="opus"', 160000),
        a(140, 'audio/mp4; codecs="mp4a.40.2"', 128000),
        a(140, 'audio/mp4; codecs="mp4a.40.2"', 128000),
        a(328, 'audio/mp4; codecs="ec-3"', 500000),
      ]));
      expect(dash.playable, isTrue);
      expect(
        dash.videos.map((v) => v.itag),
        [299, 18, 303],
      );
      expect(
        dash.audios.map((a) => a.itag),
        [251, 140],
      );
    });

    test('dry or ciphered-only is not playable', () {
      expect(
        ArchtubeClient.parseAdaptiveStreams({}).playable,
        isFalse,
      );
      expect(
        ArchtubeClient.parseAdaptiveStreams(dashJson([
          {'itag': 137, 'signatureCipher': 's=abc'},
        ])).playable,
        isFalse,
      );
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

  group('resolveDashRange', () {
    void expectRange(String? header, int len, int start, int end) {
      final r = resolveDashRange(header, len)!;
      expect(r.start, start);
      expect(r.end, end);
    }

    test('bare and open ranges cover the body', () {
      expectRange(null, 1000, 0, 999);
      expectRange('bytes=0-', 1000, 0, 999);
      expectRange('bytes=200-499', 1000, 200, 499);
    });

    test('suffix and clamping', () {
      expectRange('bytes=-200', 1000, 800, 999);
      expectRange('bytes=900-9999', 1000, 900, 999);
      expectRange('garbage', 1000, 0, 999);
    });

    test('past-the-end is unsatisfiable, unknown length passes through', () {
      final r = resolveDashRange('bytes=2000-', 1000)!;
      expect(r.end < r.start, isTrue);
      expect(resolveDashRange('bytes=0-', 0), isNull);
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
    ArchtubeHit hit(String id, String title, String channel, int? secs) =>
        ArchtubeHit(
            videoId: id, title: title, channel: channel,
            durationSecs: secs);

    test('bias to same song in a longer video', () {
      final won = pickMatch(
        hits: [
          hit('shortone111', 'Song', 'A', 195),
          hit('longone2222', 'Song Official Music Video', 'A', 208),
        ],
        artist: 'A',
        title: 'Song',
        songSecs: 200,
      );
      expect(won?.videoId, 'longone2222');
    });

    test('window excludes far cuts, null durations skipped', () {
      expect(
        pickMatch(
          hits: [
            hit('farfarfar11', 'Song extended set', 'A', 900),
            hit('nodurnone11', 'Song', 'A', null),
          ],
          artist: 'A',
          title: 'Song',
          songSecs: 200,
        ),
        isNull,
      );
    });

    test('short cuts rejected, longs tolerated asymmetrically', () {
      expect(
        pickMatch(
          hits: [hit('tooshort111', 'Song', 'A', 180)],
          artist: 'A',
          title: 'Song',
          songSecs: 200,
        ),
        isNull,
      );
      final won = pickMatch(
        hits: [hit('longish1111', 'Song', 'A', 260)],
        artist: 'A',
        title: 'Song',
        songSecs: 200,
      );
      expect(won?.videoId, 'longish1111');
    });

    test('vevo lane beats a plain upload', () {
      final won = pickMatch(
        hits: [
          hit('plainplain1', 'Song', 'Some Fan', 200),
          hit('vevovevo111', 'Song', 'AVevo', 200),
        ],
        artist: 'A',
        title: 'Song',
        songSecs: 200,
      );
      expect(won?.videoId, 'vevovevo111');
    });

    test('live cut loses to the official one', () {
      final won = pickMatch(
        hits: [
          hit('livelive111', 'Song Live At The Arena', 'A', 230),
          hit('official111', 'Song Official Music Video', 'A', 215),
        ],
        artist: 'A',
        title: 'Song',
        songSecs: 200,
      );
      expect(won?.videoId, 'official111');
    });

    test('rejected ids never re-win', () {
      final won = pickMatch(
        hits: [
          hit('badbadbad11', 'Song Official Music Video', 'AVevo', 205),
          hit('goodgood111', 'Song', 'A', 200),
        ],
        artist: 'A',
        title: 'Song',
        songSecs: 200,
        excluded: {'badbadbad11'},
      );
      expect(won?.videoId, 'goodgood111');
    });

    test('lyric upload loses to the artist channel video', () {
      final won = pickMatch(
        hits: [
          hit('lyriclyric1', 'Hurricane (Lyrics)', 'Lyric Heaven', 179),
          hit('official111', 'Hurricane (Official Music Video)',
              'Kanye West', 263),
        ],
        artist: 'Kanye West',
        title: 'Hurricane',
        songSecs: 179,
      );
      expect(won?.videoId, 'official111');
    });

    test('audio upload is last resort only', () {
      final lonely = pickMatch(
        hits: [
          hit('audioaudio1', 'Song (Official Audio)', 'A', 200),
        ],
        artist: 'A',
        title: 'Song',
        songSecs: 200,
      );
      expect(lonely?.videoId, 'audioaudio1');
      final beaten = pickMatch(
        hits: [
          hit('audioaudio1', 'Song (Official Audio)', 'A', 200),
          hit('stagedstage', 'Song', 'A Fan', 205),
        ],
        artist: 'A',
        title: 'Song',
        songSecs: 200,
      );
      expect(beaten?.videoId, 'stagedstage');
    });

    test('anime full version wins over the tv size cut', () {
      final won = pickMatch(
        hits: [
          hit('tvsize11111', 'Bloody Stream TV Size', 'Anime Tunes', 90),
          hit('fullfull111', 'Bloody Stream Full Version', 'Anime Tunes',
              245),
          hit('lyriclyric1', 'Bloody Stream Lyrics', 'Lyric Heaven', 243),
        ],
        artist: 'Coda',
        title: 'Bloody Stream',
        songSecs: 243,
      );
      expect(won?.videoId, 'fullfull111');
    });

    test('empty hits is null', () {
      expect(pickMatch(hits: [], artist: 'A', title: 'Song', songSecs: 200),
          isNull);
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

  group('PlayerCipher (original solver, synthetic base.js)', () {
    const js = '''
var AB={rv:function(a){a.reverse()},sp:function(a,b){a.splice(0,b)},sw:function(a,b){var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c}};
var CD=function(a){a=a.split("");AB.sw(a,3);AB.rv(a);AB.sp(a,2);return a.join("")};
a.set("alr","yes");c&&(c=CD(c));
var EF=function(a){var b=a.split("");b.splice(0,2);b.reverse();return b.join("")};
b=a.get("n"))&&(b=EF(b));
''';

    test('parses sig + n recipes from structural anchors', () {
      final cipher = PlayerCipher.parsePlayerJs(js, 'test123');
      expect(cipher.sigOps.length, 3);
      expect(cipher.sigOps[0].op, CipherOp.swap);
      expect(cipher.sigOps[1].op, CipherOp.reverse);
      expect(cipher.sigOps[2].op, CipherOp.splice);
      expect(cipher.canDescrambleN, isTrue);
    });

    test('sig descramble applies swap/reverse/splice in order', () {
      final cipher = PlayerCipher.parsePlayerJs(js, 'test123');
      expect(cipher.descrambleSig('abcdef'), 'acbd');
    });

    test('n descramble applies inline splice + reverse', () {
      final cipher = PlayerCipher.parsePlayerJs(js, 'test123');
      expect(cipher.descrambleN('abcdef'), 'fedc');
    });

    test('rebuildUrl re-attaches sig under sp, keeps n without recipe',
        () {
      const noN = '''
var AB={rv:function(a){a.reverse()}};
var CD=function(a){a=a.split("");AB.rv(a);return a.join("")};
a.set("alr","yes");c&&(c=CD(c));
''';
      final cipher = PlayerCipher.parsePlayerJs(noN, 'v2');
      expect(cipher.canDescrambleN, isFalse);
      final url = cipher.rebuildUrl(
        's=abcdef&sp=sig&url=https%3A%2F%2Fexample.com%2Fv%3Fn%3Dpq',
      );
      expect(url, 'https://example.com/v?n=pq&sig=fedcba');
    });

    test('unknown shapes throw instead of guessing', () {
      expect(
        () => PlayerCipher.parsePlayerJs('var x = 1;', 'v9'),
        throwsStateError,
      );
    });

    test('watch helpers: player url, version, visitorData', () {
      const html =
          '{"PLAYER_JS_URL":"/s/player/abc123/base.js","visitorData":"Cgt123=="}';
      expect(
        PlayerCipher.playerJsUrlOfWatch(html),
        'https://www.youtube.com/s/player/abc123/base.js',
      );
      expect(
        PlayerCipher.playerVersionOf(
          'https://www.youtube.com/s/player/abc123/base.js',
        ),
        'abc123',
      );
      expect(PlayerCipher.visitorDataOfWatch(html), 'Cgt123==');
      expect(PlayerCipher.playerJsUrlOfWatch('{}'), isNull);
    });
  });

  group('PoTokenSlot', () {
    test('applies poToken without blocking on visitorData', () {
      PoTokenSlot.clearForTest();
      final body = <String, dynamic>{
        'context': archtubeLadder.first.contextPayload(),
        'videoId': 'aqz-KE-bpKQ',
      };
      final headers = <String, String>{};
      PoTokenSlot.setPoToken('tok123');
      PoTokenSlot.apply(body, headers);
      expect(
        (body['serviceIntegrityDimensions'] as Map)['poToken'],
        'tok123',
      );
      PoTokenSlot.clearForTest();
    });
  });

  group('UpstreamEngine', () {
    test('always yields a client, cronet or dart', () {
      expect(UpstreamEngine.client(), isA<http.BaseClient>());
    });
  });
}
