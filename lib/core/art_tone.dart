import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Dominant muted tone of a network image, for melting heroes into pages.
/// No new packages: fetches bytes (already-cached URLs in practice),
/// decodes at 32px via the engine codec, averages opaque pixels, mutes
/// toward a tonal wash. Session-memory cached. Null = use neutral wash.
abstract final class ArtTone {
  static final Map<String, Color?> _memo = {};

  static Future<Color?> of(String? url) async {
    if (url == null || url.isEmpty) return null;
    if (_memo.containsKey(url)) return _memo[url];
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        _memo[url] = null;
        return null;
      }
      final codec = await ui.instantiateImageCodec(res.bodyBytes, targetWidth: 32);
      final frame = await codec.getNextFrame();
      final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (bytes == null) {
        _memo[url] = null;
        return null;
      }
      var r = 0, g = 0, b = 0, n = 0;
      final data = bytes.buffer.asUint8List();
      for (var i = 0; i + 3 < data.length; i += 4) {
        if (data[i + 3] < 128) continue;
        r += data[i];
        g += data[i + 1];
        b += data[i + 2];
        n++;
      }
      if (n == 0) {
        _memo[url] = null;
        return null;
      }
      // Mute toward a calm wash: desaturate ~35% around mid gray.
      double fr = r / n, fg = g / n, fb = b / n;
      const gray = 200.0;
      fr += (gray - fr) * 0.35;
      fg += (gray - fg) * 0.35;
      fb += (gray - fb) * 0.35;
      final tone = Color.fromARGB(
          255, fr.clamp(0, 255).round(), fg.clamp(0, 255).round(), fb.clamp(0, 255).round());
      _memo[url] = tone;
      return tone;
    } catch (_) {
      _memo[url] = null;
      return null;
    }
  }
}
