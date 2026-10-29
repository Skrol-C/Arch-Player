/// Archtube disguise roster: the client identities our own minimal
/// InnerTube client wears when talking to `youtubei/v1/player`
/// (and `search`). ANDROID first: it still returns progressive
/// itag 18 with direct URLs, no signature deciphering. When a
/// client comes back dry (no usable progressive stream) the ladder
/// rotates to the next identity instead of inventing new crypto.
///
/// API keys below are the public embedded keys each platform client
/// ships with, the same ones every open InnerTube client uses.
/// They identify the client build, not the user.
class ArchtubeIdentity {
  final String clientName;
  final String clientVersion;
  final String apiKey;
  final String userAgent;
  final int? androidSdkVersion;

  const ArchtubeIdentity({
    required this.clientName,
    required this.clientVersion,
    required this.apiKey,
    required this.userAgent,
    this.androidSdkVersion,
  });

  /// The `context.client` payload for youtubei calls.
  Map<String, dynamic> contextPayload() => {
        'client': {
          'clientName': clientName,
          'clientVersion': clientVersion,
          if (androidSdkVersion != null)
            'androidSdkVersion': androidSdkVersion,
          'hl': 'en',
          'gl': 'US',
        },
      };
}

/// Fallback ladder, in order. Borrowed from innertube-rs, not the lib.
const archtubeLadder = <ArchtubeIdentity>[
  ArchtubeIdentity(
    clientName: 'ANDROID',
    clientVersion: '20.10.38',
    apiKey: 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
    userAgent:
        'com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip',
    androidSdkVersion: 34,
  ),
  ArchtubeIdentity(
    clientName: 'iOS',
    clientVersion: '20.10.38',
    apiKey: 'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
    userAgent:
        'com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)',
  ),
  ArchtubeIdentity(
    clientName: 'ANDROID_VR',
    clientVersion: '1.43.32',
    apiKey: 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
    userAgent:
        'com.google.android.apps.youtube.vr/1.43.32 (Linux; U; Android 12) gzip',
    androidSdkVersion: 32,
  ),
  ArchtubeIdentity(
    clientName: 'MWEB',
    clientVersion: '2.20251027.00.00',
    apiKey: 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
    userAgent:
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  ),
];
