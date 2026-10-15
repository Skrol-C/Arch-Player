import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Search filter pills: client-side filter over the mixed
/// customSearch result (item_type), never a re-query.
enum SearchFilter { all, songs, artists, albums, playlists }

extension SearchFilterLabel on SearchFilter {
  String get label => switch (this) {
        SearchFilter.all => 'All',
        SearchFilter.songs => 'Songs',
        SearchFilter.artists => 'Artists',
        SearchFilter.albums => 'Albums',
        SearchFilter.playlists => 'Playlists',
      };
}

final searchFilterProvider =
    StateProvider<SearchFilter>((ref) => SearchFilter.all);

/// Selected metadata provider id. Empty = automatic (first-ok-wins
/// across enabled providers, priority order).
final searchProviderIdProvider =
    NotifierProvider<SearchProviderIdNotifier, String>(
        SearchProviderIdNotifier.new);

class SearchProviderIdNotifier extends Notifier<String> {
  static const _key = 'arch.search.provider';

  @override
  String build() {
    _sync();
    return '';
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_key) ?? '';
  }

  Future<void> set(String id) async {
    state = id;
    (await SharedPreferences.getInstance()).setString(_key, id);
  }
}

/// Per-provider getTrack capability (preview fallback path).
/// Probed once per search, best-effort; absent = unknown.
final previewCapableProvider =
    StateProvider<Map<String, bool>>((ref) => const {});
