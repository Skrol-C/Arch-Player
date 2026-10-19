import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Color;

import '../../core/log.dart';
import '../../core/models.dart';
import '../library/data/art_previews.dart';

/// Dominant cover color per song, computed off the cached preview
/// (32px decode — cheap) and memoized. Drives the reabsorb wash:
/// each diving row flashes its own song's color on the portrait.
/// Misses read as null so a song without readable art simply skips
/// its flash step instead of stalling the choreography.
final _cache = <int, Color>{};

Future<Color?> dominantCoverColor(Song song) async {
  if (song.path.isEmpty) return null;
  final hit = _cache[song.id];
  if (hit != null) return hit;
  try {
    final preview = await ArtPreviews.previewFor(song.path);
    final file = File(preview ?? song.path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 32);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data == null) return null;
    final px = data.buffer.asUint8List();
    var r = 0.0, g = 0.0, b = 0.0, n = 0;
    var fr = 0.0, fg = 0.0, fb = 0.0, fn = 0;
    for (var i = 0; i + 3 < px.length; i += 4) {
      final rr = px[i].toDouble(),
          gg = px[i + 1].toDouble(),
          bb = px[i + 2].toDouble();
      r += rr;
      g += gg;
      b += bb;
      n++;
      final mx = rr > gg ? (rr > bb ? rr : bb) : (gg > bb ? gg : bb);
      final mn = rr < gg ? (rr < bb ? rr : bb) : (gg < bb ? gg : bb);
      // Vivid pixels vote for the flash; murk votes for fallback.
      if (mx - mn > 28 && mx > 40 && mn < 215) {
        fr += rr;
        fg += gg;
        fb += bb;
        fn++;
      }
    }
    if (n == 0) return null;
    Color out;
    if (fn > 0) {
      out = Color.fromARGB(
          255, (fr / fn).round(), (fg / fn).round(), (fb / fn).round());
    } else {
      out = Color.fromARGB(
          255, (r / n).round(), (g / n).round(), (b / n).round());
    }
    _cache[song.id] = out;
    return out;
  } catch (e) {
    ArchLog.w('home', 'dominant color failed: $e');
    return null;
  }
}
