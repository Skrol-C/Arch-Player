/// Search provider marks: extension id/displayName -> bundled asset.
/// Null = no mark file (SoundCloud and any future source); the picker
/// renders an initial-letter avatar instead. Never blank, never a
/// broken image.
String? providerMarkAsset(String id, String displayName) {
  final s = '${id.toLowerCase()} ${displayName.toLowerCase()}';
  if (s.contains('spotify')) return 'assets/providers/spotify.svg';
  if (s.contains('apple')) return 'assets/providers/apple_music.svg';
  if (s.contains('deezer')) return 'assets/providers/deezer.svg';
  if (s.contains('tidal')) return 'assets/providers/tidal.svg';
  if (s.contains('qobuz')) return 'assets/providers/qobuz.svg';
  if (s.contains('youtube') || s.contains('ytmusic') || s.contains('ytm')) {
    return 'assets/providers/youtube_music.svg';
  }
  if (s.contains('amazon')) return 'assets/providers/amazon_music.svg';
  return null;
}

/// Wide wordmark variants for roomy surfaces (dropdown rows). Square
/// tiles keep the letter fallback for these: a 124x14 wordmark in a
/// 24px box is a smear, not a mark.
String? providerMarkWideAsset(String id, String displayName) {
  final s = '${id.toLowerCase()} ${displayName.toLowerCase()}';
  if (s.contains('soundcloud')) return 'assets/providers/soundcloud.svg';
  return null;
}
