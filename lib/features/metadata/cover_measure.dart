import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Measured cover info: exact bytes + decoded dimensions, cheapest
/// fetch that answers both.
///
/// Cost model per URL: one HEAD (bytes) + one 64KB Range (dims).
/// PNG IHDR always sits in the first 33 bytes; JPEG SOF markers
/// almost always land inside the first chunk (large EXIF segments
/// can push them out). Anything missing falls back to a bounded
/// full GET. Worst case costs today's full download + 64KB; the
/// common case costs ~65KB total instead of megabytes. Never throws.
Future<({int bytes, int width, int height})?> measureCoverArt(
    String url) async {
  if (url.isEmpty) return null;
  try {
    // Bytes first: HEAD is free and independent of the dims fetch.
    final headFuture = http
        .head(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    final headBytes = await _rangeHead(url);
    final head = await headFuture;
    int? bytes;
    if (head.statusCode == 200) {
      bytes = int.tryParse(head.headers['content-length'] ?? '');
    }
    if (headBytes != null) {
      final dims = coverDimsFromHead(headBytes);
      if (dims != null) {
        return (
          bytes: bytes ?? headBytes.length,
          width: dims.$1,
          height: dims.$2
        );
      }
    }
    // Fallback: bounded full fetch, same caps the embed path uses.
    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 ||
        res.bodyBytes.isEmpty ||
        res.bodyBytes.length > 10 * 1024 * 1024) {
      return null;
    }
    final dims = coverDimsFromHead(res.bodyBytes);
    if (dims == null) return null;
    return (
      bytes: res.bodyBytes.length,
      width: dims.$1,
      height: dims.$2
    );
  } catch (_) {
    return null;
  }
}

/// First ~64KB of a URL, Range-requested. Caps cost even when the
/// server ignores Range: the stream is cut locally at 70KB.
Future<Uint8List?> _rangeHead(String url) async {
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers['Range'] = 'bytes=0-65535';
    final resp =
        await client.send(req).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200 && resp.statusCode != 206) return null;
    final buf = BytesBuilder();
    await for (final chunk in resp.stream) {
      final room = 70000 - buf.length;
      if (room <= 0) break;
      buf.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
    }
    final out = buf.toBytes();
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// (width, height) from image header bytes, or null. Bounds-checked
/// throughout: a truncated Range slice must read as "unknown", never
/// throw. PNG IHDR is fixed-offset; JPEG walks segments to SOF0-3.
(int, int)? coverDimsFromHead(Uint8List b) {
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    final w =
        (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final h =
        (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    if (w > 0 && h > 0) return (w, h);
    return null;
  }
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var pos = 2;
  while (pos + 4 <= b.length) {
    if (b[pos] != 0xFF) return null;
    final marker = b[pos + 1];
    if (marker == 0xD8 || marker == 0xD9) {
      pos += 2;
      continue;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      pos += 2;
      continue;
    }
    if (pos + 4 > b.length) return null;
    final segLen = (b[pos + 2] << 8) | b[pos + 3];
    if (segLen < 2 || pos + 2 + segLen > b.length) return null;
    if (marker >= 0xC0 &&
        marker <= 0xC3 &&
        pos + 10 <= b.length) {
      final h = (b[pos + 5] << 8) | b[pos + 6];
      final w = (b[pos + 7] << 8) | b[pos + 8];
      if (w > 0 && h > 0) return (w, h);
      return null;
    }
    pos += 2 + segLen;
  }
  return null;
}

/// Longest side at or above this reads as high quality. Matches the
/// embed cap: anything past it survives embedding intact.
const kHqSide = 1400;

/// "2.4 MB" / "812 KB" for chips.
String formatArtBytes(int b) => b >= 1048576
    ? '${(b / 1048576).toStringAsFixed(1)} MB'
    : '${(b / 1024).round()} KB';
