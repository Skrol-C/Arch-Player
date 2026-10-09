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
