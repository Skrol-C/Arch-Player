import 'package:shared_preferences/shared_preferences.dart';

/// Folders the user chose (guided setup first, add-more later) plus
/// include/exclude toggles and followed artists. Unlimited, persisted.
class FolderStore {
  static const _pickedKey = 'picked_folders';
  static const _excludedKey = 'excluded_folders';
  static const _followedKey = 'followed_artists';
  static const _setupDoneKey = 'setup_done';

  Future<bool> get setupDone async =>
      (await SharedPreferences.getInstance()).getBool(_setupDoneKey) ?? false;

  Future<void> setSetupDone() async =>
      (await SharedPreferences.getInstance()).setBool(_setupDoneKey, true);

  Future<Set<String>> picked() async =>
      (await SharedPreferences.getInstance()).getStringList(_pickedKey)?.toSet() ?? {};

  Future<void> addPicked(String uri) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_pickedKey) ?? []).toSet()..add(uri);
    await prefs.setStringList(_pickedKey, set.toList());
  }

  Future<void> removePicked(String uri) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_pickedKey) ?? []).toSet()..remove(uri);
    await prefs.setStringList(_pickedKey, set.toList());
  }

  Future<Set<String>> excluded() async =>
      (await SharedPreferences.getInstance()).getStringList(_excludedKey)?.toSet() ?? {};

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

  Future<Set<String>> followedArtists() async =>
      (await SharedPreferences.getInstance()).getStringList(_followedKey)?.toSet() ?? {};

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
