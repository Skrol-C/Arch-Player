import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import 'metadata_service.dart';

final metadataServiceProvider = Provider<MetadataService>((ref) => MetadataService());

final artistMetaProvider = FutureProvider.family<ArtistMeta, String>((ref, artistName) {
  return ref.watch(metadataServiceProvider).enrich(artistName);
});

/// Independent progressive providers: pic, bio, and discography render
/// the moment each lands instead of waiting on the slowest.
final artistPicProvider = FutureProvider.family<String?, String>((ref, artistName) {
  return ref.watch(metadataServiceProvider).picFor(artistName);
});

final artistBioProvider = FutureProvider.family<String?, String>((ref, artistName) {
  return ref.watch(metadataServiceProvider).bioFor(artistName);
});

final artistReleasesProvider =
    FutureProvider.family<List<ReleaseGroup>, String>((ref, artistName) {
  return ref.watch(metadataServiceProvider).releasesFor(artistName);
});

/// True artist wordmark (fanart.tv HD ClearLogo), when one exists.
/// Null = the hero falls back to our display-font voice.
final artistLogoProvider = FutureProvider.family<String?, String>((ref, artistName) {
  return ref.watch(metadataServiceProvider).logoFor(artistName);
});

/// Chart top tracks, fresh per page open (preview URLs expire).
final artistTopProvider = FutureProvider.family<List<TopTrack>, String>((ref, artistName) {
  return ref.watch(metadataServiceProvider).topTracks(artistName);
});

/// Release cover art, resolved lazily per visible item.
final releaseCoverProvider = FutureProvider.family<String?, String>((ref, rgMbid) {
  return ref.watch(metadataServiceProvider).coverFor(rgMbid);
});
