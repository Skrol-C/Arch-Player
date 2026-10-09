import 'package:shared_preferences/shared_preferences.dart';

/// Unlimited folder include/exclude toggles. Keys look like `media:Music`.
class FolderStore {
  static const _excludedKey = 'excluded_folders';
  static const _followedKey = 'followed_artists';

  Future<Set<String>> excluded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_excludedKey)?.toSet() ?? {};
  }

  Future<void> setExcluded(String key, bool excluded) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_excludedKey) ?? []).toSet();
    if (excluded) {
      set.add(key);
    } else {
      set.remove(key);
    }
    await prefs.setStringList(_excludedKey, set.toList());
  }

  Future<Set<String>> followedArtists() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_followedKey)?.toSet() ?? {};
  }

  Future<void> setFollowed(String artist, bool followed) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_followedKey) ?? []).toSet();
    if (followed) {
      set.add(artist);
    } else {
      set.remove(artist);
    }
    await prefs.setStringList(_followedKey, set.toList());
  }
}
