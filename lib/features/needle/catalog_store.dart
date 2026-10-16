import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';

/// Catalog: every landed pull filed with its date, provider, and
/// quality. Written at publish time by the queue runner; read by
/// the hub Catalog pane (albums + tracks sections). Bounded.
class CatalogEntry {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String art;
  final String provider;
  final String quality;
  final int landedMs;
  final String path;
  final String format;

  /// Release type as routed at pull time ('', 'single', 'ep').
  /// Stored because the tag alone lies: a single carries an album
  /// name, and without this the catalog files it as an album while
  /// the file itself sits in Songs/.
  final String releaseType;

  const CatalogEntry({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.art = '',
    required this.provider,
    required this.quality,
    required this.landedMs,
    this.path = '',
    this.format = '',
    this.releaseType = '',
  });

  /// Albums group; everything else is a track. Mirrors the routing
  /// in `_needleRelPath`: singles and EPs are tracks even when they
  /// name an album, because that is where they actually landed.
  bool get isAlbum {
    final rt = releaseType.trim().toLowerCase();
    if (rt == 'single' || rt == 'ep') return false;
    return album.trim().isNotEmpty;
  }

  /// Same recording identity, for re-pull replacement.
  bool sameTrackAs(String otherTitle, String otherArtist) =>
      title.trim().toLowerCase() == otherTitle.trim().toLowerCase() &&
      artist.trim().toLowerCase() == otherArtist.trim().toLowerCase();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'art': art,
        'provider': provider,
        'quality': quality,
        'landedMs': landedMs,
        'path': path,
        'format': format,
        'releaseType': releaseType,
      };

  static CatalogEntry? fromJson(Map m) {
    try {
      return CatalogEntry(
        id: (m['id'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        artist: (m['artist'] as String?) ?? '',
        album: (m['album'] as String?) ?? '',
        art: (m['art'] as String?) ?? '',
        provider: (m['provider'] as String?) ?? '',
        quality: (m['quality'] as String?) ?? '',
        landedMs: (m['landedMs'] as num?)?.toInt() ?? 0,
        path: (m['path'] as String?) ?? '',
        format: (m['format'] as String?) ?? '',
        // Absent on entries filed before release types were kept.
        releaseType: (m['releaseType'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

final catalogProvider =
    NotifierProvider<CatalogNotifier, List<CatalogEntry>>(
        CatalogNotifier.new);

class CatalogNotifier extends Notifier<List<CatalogEntry>> {
  static const _key = 'arch.catalog';
  static const _cap = 500;

  @override
  List<CatalogEntry> build() {
    _sync();
    return const [];
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      state = [
        for (final e in list)
          if (e is Map && CatalogEntry.fromJson(e) != null)
            CatalogEntry.fromJson(e)!,
      ];
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode([for (final e in state) e.toJson()]));
  }

  Future<void> record(CatalogEntry e) async {
    state = [
      e,
      for (final x in state)
        if (x.id != e.id) x,
    ].take(_cap).toList();
    await _save();
  }

  /// Prior copies of the same recording. Re-pulls replace rather
  /// than pile up numbered duplicates.
  List<CatalogEntry> priorFor(String title, String artist) =>
      [for (final e in state) if (e.sameTrackAs(title, artist)) e];

  /// Drop entries by id; returns what was removed so the caller can
  /// report it (and, when native delete lands, remove the files).
  Future<List<CatalogEntry>> removeIds(Set<String> ids) async {
    if (ids.isEmpty) return const [];
    final gone = [for (final e in state) if (ids.contains(e.id)) e];
    if (gone.isEmpty) return const [];
    state = [for (final e in state) if (!ids.contains(e.id)) e];
    await _save();
    ArchLog.i('catalog',
        'unfiled ${gone.length} ${gone.length == 1 ? 'entry' : 'entries'}');
    return gone;
  }
}
