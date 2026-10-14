import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/log.dart';

/// Play history: counts + last-played per song id. Feeds Listen Again,
/// most-played shelves, and future taste. Bounded (500 entries, LRU-ish
/// by timestamp trim) so it can never grow into a problem.
class HistoryStore {
  static const _key = 'play_history_v1';
  static const _cap = 500;

  /// songId -> {count, lastMs}
  Future<Map<int, PlayRecord>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return {};
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in map.entries)
          int.parse(e.key): PlayRecord.fromMap(e.value as Map<String, dynamic>),
      };
    } catch (e) {
      ArchLog.w('history', 'read failed: $e');
      return {};
    }
  }

  Future<void> recordPlay(int songId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await read();
      final now = DateTime.now().millisecondsSinceEpoch;
      final prev = all[songId];
      all[songId] = PlayRecord(count: (prev?.count ?? 0) + 1, lastMs: now);
      if (all.length > _cap) {
        final sorted = all.entries.toList()
          ..sort((a, b) => a.value.lastMs.compareTo(b.value.lastMs));
        for (final e in sorted.take(all.length - _cap)) {
          all.remove(e.key);
        }
      }
      await prefs.setString(
        _key,
        jsonEncode({for (final e in all.entries) '${e.key}': e.value.toMap()}),
      );
    } catch (e) {
      ArchLog.w('history', 'record failed: $e');
    }
  }
}

class PlayRecord {
  final int count;
  final int lastMs;

  const PlayRecord({required this.count, required this.lastMs});

  factory PlayRecord.fromMap(Map<String, dynamic> m) => PlayRecord(
    count: (m['c'] as num?)?.toInt() ?? 0,
    lastMs: (m['l'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toMap() => {'c': count, 'l': lastMs};
}
