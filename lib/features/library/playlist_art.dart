import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/art_tone.dart';
import '../../core/models.dart';
import '../library/data/library_repository.dart';

/// Playlist artwork = an auto-gradient distilled from the member
/// tracks' own cover art (the `Yeah` rule). No uploads, no stored
/// images: the first songs with art each contribute their vibrant
/// pick, blended top-light to bottom-deep. Empty playlists fall back
/// to a neutral tile so nothing ever renders blank.
abstract final class PlaylistArt {
  /// Ordered gradient stops for these songs. At least 2 entries,
  /// always; callers paint a LinearGradient straight from this.
  static Future<List<Color>> gradientFor(List<Song> songs) async {
    final picks = <Color>[];
    for (final s in songs) {
      if (picks.length >= 4) break;
      if (s.albumId <= 0) continue;
      try {
        final pal = await ArtTone.paletteFromBytes(
          'art:${s.albumId}',
          () => ArtCache.of(s.albumId, ArtBucket.large),
        );
        if (pal == null) continue;
        final c = pal.vibrant;
        // Skip near-duplicates so 4 tracks off one album still vary.
        if (picks.any((p) => _close(p, c))) continue;
        picks.add(c);
      } catch (_) {}
    }
    if (picks.isEmpty) return [fallbackTop, fallbackBottom];
    if (picks.length == 1) {
      final c = picks.first;
      return [lighten(c), c, darken(c)];
    }
    // Lightest up top, deepest at the bottom: the ref's falloff.
    picks.sort(
      (a, b) => b.computeLuminance().compareTo(a.computeLuminance()),
    );
    if (picks.length == 2) return [picks[0], picks[1]];
    return [picks[0], picks[1], picks.last];
  }

  static const fallbackTop = Color(0xFFC9A8E8);
  static const fallbackBottom = Color(0xFF5B2A86);

  static Color lighten(Color c) => Color.lerp(c, Colors.white, 0.35) ?? c;
  static Color darken(Color c) => Color.lerp(c, Colors.black, 0.3) ?? c;

  static bool _close(Color a, Color b) {
    return (a.r - b.r).abs() < 0.08 &&
        (a.g - b.g).abs() < 0.08 &&
        (a.b - b.b).abs() < 0.08;
  }

  /// Full-bleed page color for the detail hero: the gradient's
  /// midpoint pulled toward the page so text always reads. Same
  /// contrast-clamp discipline as artist/album washes.
  static Color washFor(List<Color> stops,
      {bool dark = false, bool amoled = false}) {
    if (stops.isEmpty) {
      return ArtTone.pageWashOf(null, dark: dark, amoled: amoled);
    }
    var r = 0.0, g = 0.0, b = 0.0;
    for (final c in stops) {
      r += c.r;
      g += c.g;
      b += c.b;
    }
    final mid = Color.from(
      alpha: 1,
      red: r / stops.length,
      green: g / stops.length,
      blue: b / stops.length,
    );
    return ArtTone.pageWashOf(mid, dark: dark, amoled: amoled);
  }

  /// Ink or white for text sitting ON the gradient tile itself.
  static Color onGradient(List<Color> stops) {
    if (stops.isEmpty) return Colors.white;
    final deep = stops.last;
    return deep.computeLuminance() > 0.4 ? const Color(0xFF0B0B0D) : Colors.white;
  }

  /// Drop memoized cover bytes + palette for a path that was just
  /// overwritten or deleted, so the next read hits disk.
  static void evictCover(String path) {
    if (path.isEmpty) return;
    _coverMemo.remove(path);
    ArtTone.evict('playlist:$path');
  }

  /// Read a persisted custom cover's bytes, or null when missing.
  /// Memoized per path: tiles rebuild often, disk should not.
  static final Map<String, Uint8List?> _coverMemo = {};

  static Future<Uint8List?> coverBytes(String path) async {
    if (path.isEmpty) return null;
    if (_coverMemo.containsKey(path)) return _coverMemo[path];
    try {
      final f = File(path);
      if (!await f.exists()) {
        _coverMemo[path] = null;
        return null;
      }
      final bytes = await f.readAsBytes();
      final out = bytes.isEmpty ? null : bytes;
      _coverMemo[path] = out;
      while (_coverMemo.length > 32) {
        _coverMemo.remove(_coverMemo.keys.first);
      }
      return out;
    } catch (_) {
      _coverMemo[path] = null;
      return null;
    }
  }

  /// Voice color for a custom cover's fancy name: the palette's
  /// vibrant pick, white when it sits too close to its own backdrop
  /// to read. Same closeness rule as artist heroes.
  static Color coverVoiceColor(ArtPalette? palette) {
    if (palette == null) return Colors.white;
    final vibrant = palette.vibrant;
    final close =
        (vibrant.computeLuminance() - palette.photoLum).abs() < 0.25;
    return close ? Colors.white : vibrant;
  }
}
