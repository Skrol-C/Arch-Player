import 'video_providers.dart' show VideoOption;

/// One adaptation lane in the manifest: a picked picture lane or the
/// paired sound lane, with the proxy URL ExoPlayer actually fetches.
class ManifestLane {
  final String id;
  final String mimeType;
  final String codecs;
  final int bandwidth;
  final int width;
  final int height;
  final String baseUrl;
  final int initStart;
  final int initEnd;
  final int indexStart;
  final int indexEnd;

  const ManifestLane({
    required this.id,
    required this.mimeType,
    required this.codecs,
    required this.bandwidth,
    required this.width,
    required this.height,
    required this.baseUrl,
    required this.initStart,
    required this.initEnd,
    required this.indexStart,
    required this.indexEnd,
  });

  /// Lane out of a picked picture option plus its proxy URL.
  factory ManifestLane.video(VideoOption option, String proxyUrl) =>
      ManifestLane(
        id: 'v${option.itag}',
        mimeType:
            option.mime.startsWith('video/') ? option.mime : 'video/mp4',
        codecs: option.codecs,
        bandwidth: 0,
        width: option.width,
        height: option.height,
        baseUrl: proxyUrl,
        initStart: option.initStart,
        initEnd: option.initEnd,
        indexStart: option.indexStart,
        indexEnd: option.indexEnd,
      );

  /// Lane out of the paired sound option plus its proxy URL.
  factory ManifestLane.audio(VideoOption option, String proxyUrl) =>
      ManifestLane(
        id: 'a${option.itag}',
        mimeType:
            option.mime.startsWith('audio/') ? option.mime : 'audio/mp4',
        codecs: option.codecs,
        bandwidth: 0,
        width: 0,
        height: 0,
        baseUrl: proxyUrl,
        initStart: option.initStart,
        initEnd: option.initEnd,
        indexStart: option.indexStart,
        indexEnd: option.indexEnd,
      );
}

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _representation(ManifestLane lane, {required bool video}) {
  final size = video && lane.width > 0 && lane.height > 0
      ? ' width="${lane.width}" height="${lane.height}"'
      : '';
  final codecs =
      lane.codecs.isEmpty ? '' : ' codecs="${_escapeXml(lane.codecs)}"';
  final mime = lane.mimeType.split(';').first.trim();
  return '<Representation id="${lane.id}" mimeType="$mime"$size$codecs>'
      '<BaseURL>${_escapeXml(lane.baseUrl)}</BaseURL>'
      '<SegmentBase indexRange="${lane.indexStart}-${lane.indexEnd}">'
      '<Initialization range="${lane.initStart}-${lane.initEnd}"/>'
      '</SegmentBase>'
      '</Representation>';
}

/// Static on-demand manifest for exactly one picture lane plus one
/// sound lane: manual quality stays exact (the picked itag is the
/// only video representation), sync is sample-accurate by
/// construction, and one player means one audio-focus holder.
/// URLs must be the loopback proxy legs, never signed googlevideo
/// URLs straight: the player ranges through the proxy like before.
String buildDashManifest({
  required ManifestLane video,
  required ManifestLane audio,
  required int durationSecs,
}) {
  final duration = durationSecs > 0 ? durationSecs : 1;
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<MPD type="static" mediaPresentationDuration="PT${duration}S" '
      'minBufferTime="PT1.5S" '
      'profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" '
      'xmlns="urn:mpeg:dash:schema:mpd:2011">'
      '<Period duration="PT${duration}S">'
      '<AdaptationSet mimeType="${video.mimeType.split(';').first.trim()}" '
      'contentType="video">'
      '${_representation(video, video: true)}'
      '</AdaptationSet>'
      '<AdaptationSet mimeType="${audio.mimeType.split(';').first.trim()}" '
      'contentType="audio">'
      '${_representation(audio, video: false)}'
      '</AdaptationSet>'
      '</Period>'
      '</MPD>';
}
