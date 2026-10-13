import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Palette pulled from one 32px decode of the artist portrait.
/// [wash] is the muted tone the page melts into; [vibrant] is the
/// saturated pick that voices the artist name; [photoLum] is the mean
/// relative luminance behind the name, driving the white-fallback call.
class ArtPalette {
  final Color wash;
  final Color vibrant;
  final double photoLum;

  const ArtPalette({required this.wash, required this.vibrant, required this.photoLum});
}

/// Dominant muted tone of a network image, for melting heroes into pages.
/// No new packages: fetches bytes (already-cached URLs in practice),
/// decodes at 32px via the engine codec, averages opaque pixels, mutes
/// toward a tonal wash. Session-memory cached. Null = use neutral wash.
abstract final class ArtTone {
  static final Map<String, Color?> _memo = {};
  static final Map<String, ArtPalette?> _paletteMemo = {};

  static Future<Color?> of(String? url) async {
    if (url == null || url.isEmpty) return null;
    if (_memo.containsKey(url)) return _memo[url];
    final palette = await paletteOf(url);
    final tone = palette?.wash;
    _memo[url] = tone;
    return tone;
  }

  /// Full palette in one pass. Null url (or any failure) = null, and the
  /// hero falls back to defaults that still read.
  static Future<ArtPalette?> paletteOf(String? url) async {
    if (url == null || url.isEmpty) return null;
    if (_paletteMemo.containsKey(url)) return _paletteMemo[url];
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        _paletteMemo[url] = null;
        return null;
      }
      final palette = await decode(res.bodyBytes);
      _paletteMemo[url] = palette;
      _memo[url] = palette?.wash;
      return palette;
    } catch (_) {
      _paletteMemo[url] = null;
      return null;
    }
  }

  /// Palette from already-held bytes (local album art via ArtCache):
  /// no fetch, same math. Memoized by caller key, capped - a long
  /// listening session would otherwise keep every cover's palette.
  /// Brightness is part of the contract (their per-source+brightness
  /// pattern): today's caller is always light; dark mode later flips
  /// the wash mapping, not this function.
  static final Map<String, ArtPalette?> _bytesMemo = {};

  static Future<ArtPalette?> paletteFromBytes(
      String key, Future<Uint8List?> Function() load) async {
    if (_bytesMemo.containsKey(key)) return _bytesMemo[key];
    try {
      final bytes = await load();
      if (bytes == null || bytes.isEmpty) {
        _bytesMemo[key] = null;
        return null;
      }
      final palette = await decode(bytes);
      _bytesMemo[key] = palette;
      while (_bytesMemo.length > 64) {
        _bytesMemo.remove(_bytesMemo.keys.first);
      }
      return palette;
    } catch (_) {
      _bytesMemo[key] = null;
      return null;
    }
  }

  /// One 32px engine decode -> palette. Shared by network and byte
  /// paths; null on anything undecodable.
  static Future<ArtPalette?> decode(Uint8List raw) async {
    try {
      final codec = await ui.instantiateImageCodec(raw, targetWidth: 112);
      final frame = await codec.getNextFrame();
      final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (bytes == null) return null;
      var r = 0, g = 0, b = 0, n = 0;
      // Saturated lane: the colors the artist actually wears.
      var vr = 0, vg = 0, vb = 0, vn = 0;
      final data = bytes.buffer.asUint8List();
      for (var i = 0; i + 3 < data.length; i += 4) {
        if (data[i + 3] < 128) continue;
        final pr = data[i], pg = data[i + 1], pb = data[i + 2];
        r += pr;
        g += pg;
        b += pb;
        n++;
        final mx = pr > pg ? (pr > pb ? pr : pb) : (pg > pb ? pg : pb);
        final mn = pr < pg ? (pr < pb ? pr : pb) : (pg < pb ? pg : pb);
        if (mx > 60 && mx - mn > (mx * 0.35).round()) {
          vr += pr;
          vg += pg;
          vb += pb;
          vn++;
        }
      }
      if (n == 0) return null;
      // Mute toward a calm wash: desaturate ~35% around mid gray.
      double fr = r / n, fg = g / n, fb = b / n;
      const gray = 200.0;
      fr += (gray - fr) * 0.35;
      fg += (gray - fg) * 0.35;
      fb += (gray - fb) * 0.35;
      final wash = Color.fromARGB(
          255, fr.clamp(0, 255).round(), fg.clamp(0, 255).round(), fb.clamp(0, 255).round());
      // Vibrant: saturated mean, or the dominant mean when the photo
      // runs monochrome. Never fully dark - text needs a voice.
      Color vibrant;
      if (vn > 0) {
        vibrant = Color.fromARGB(255, (vr / vn).round(), (vg / vn).round(), (vb / vn).round());
      } else {
        vibrant = Color.fromARGB(255, (r / n).round(), (g / n).round(), (b / n).round());
      }
      if (vibrant.computeLuminance() < 0.08) {
        vibrant = Color.lerp(vibrant, Colors.white, 0.25)!;
      }
      final photoLum =
          Color.fromARGB(255, (r / n).round(), (g / n).round(), (b / n).round())
              .computeLuminance();
      return ArtPalette(wash: wash, vibrant: vibrant, photoLum: photoLum);
    } catch (_) {
      return null;
    }
  }
}
