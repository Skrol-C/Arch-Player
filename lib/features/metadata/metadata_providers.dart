import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import 'metadata_service.dart';

final metadataServiceProvider = Provider<MetadataService>((ref) => MetadataService());

final artistMetaProvider = FutureProvider.family<ArtistMeta, String>((ref, artistName) {
  return ref.watch(metadataServiceProvider).enrich(artistName);
});
