import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/log.dart';
import '../../lyrics/tag_lyrics.dart';

/// A cover read straight out of the file's own tags.
class EmbeddedArt {
  final Uint8List bytes;
  final String mime;
  const EmbeddedArt(this.bytes, this.mime);
}

/// Why this exists: MediaStore serves a *downscaled rendition* of album
/// art (measured 512-750px on device) and `ArtCache` asks for the 512
/// bucket, while the full-bleed hero draws ~1200px. Files routinely
/// carry 640-1800px (measured on this library), so every screen was
/// soft while the bytes sat in the file the whole time - and because
/// MediaStore keeps ONE image per album row, a wrong cover could stick.
///
/// Reading the picture is a bounded byte-range read: no decode, no
/// scaling, no new permission, and it is per FILE rather than per
/// album. Mirrors the container walks in tag_lyrics.dart (ID3 / FLAC /
/// Ogg / MP4), pointed at the picture instead of the text.
///
/// Never throws: failure is null, never a red screen.
EmbeddedArt? readEmbeddedArt(String path) {
  if (path.isEmpty) return null;
  final lower = path.toLowerCase();
  List<int> head;
  // No existsSync() guard on purpose: it is a stat() call, and this
  // sandbox has already proven it can deny stat while allowing open.
  // A false negative there would silently kill the read forever.
  try {
    final raf = File(path).openSync();
    try {
      head = raf.readSync(12);
    } finally {
      raf.closeSync();
    }
  } catch (e) {
    ArchLog.w('art', 'cover read: cannot open ($e) $path');
    return null;
  }
  try {
    EmbeddedArt? art;
    var how = 'none';
    // Magic before extension: providers and rippers both lie.
    if (head.length >= 8 &&
        head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70) {
      how = 'mp4';
      art = _mp4Picture(path);
    } else if (head.length >= 4 &&
        head[0] == 0x66 &&
        head[1] == 0x4C &&
        head[2] == 0x61 &&
        head[3] == 0x43) {
      how = 'flac';
      art = _flacPicture(path);
    } else if (head.length >= 3 &&
        head[0] == 0x49 &&
        head[1] == 0x44 &&
        head[2] == 0x33) {
      how = 'id3';
      art = _id3Picture(path);
    } else if (head.length >= 4 &&
        head[0] == 0x4F &&
        head[1] == 0x67 &&
        head[2] == 0x67 &&
        head[3] == 0x53) {
      how = 'ogg';
      art = _oggPicture(path);
    } else if (lower.endsWith('.mp3')) {
      how = 'id3(ext)';
      art = _id3Picture(path);
    } else if (lower.endsWith('.flac')) {
      how = 'flac(ext)';
      art = _flacPicture(path);
    } else if (lower.endsWith('.m4a') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.m4b')) {
      how = 'mp4(ext)';
      art = _mp4Picture(path);
    } else if (lower.endsWith('.ogg') ||
        lower.endsWith('.oga') ||
        lower.endsWith('.opus')) {
      how = 'ogg(ext)';
      art = _oggPicture(path);
    } else {
      how = 'unknown-container';
    }
    if (art == null) {
      ArchLog.i('art', 'cover read: none in $how $path');
      return null;
    }
    ArchLog.i('art', 'cover read: ${art.bytes.length}B ${art.mime} from $how');
    return art;
  } catch (e) {
    ArchLog.w('art', 'cover read failed ($e) $path');
    return null;
  }
}

/// Ceiling for one picture. Real covers run to ~5MB (a 3000px scan);
/// anything past this is corrupt or hostile header data.
const _maxArt = 24 * 1024 * 1024;

// ---------------------------------------------------------------- ID3

EmbeddedArt? _id3Picture(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final head = raf.readSync(10);
      if (head.length < 10) return null;
      final ver = head[3];
      if (ver != 2 && ver != 3 && ver != 4) return null;
      final flags = head[5];
      final tagSize = _syncSafe(head, 6);
      if (tagSize <= 0) return null;
      final hdrLen = ver == 2 ? 6 : 10;
      var pos = 10;
      final end = 10 + tagSize;
      // Extended header sits first when the flag is set.
      if ((flags & 0x40) != 0) {
        raf.setPositionSync(pos);
        final ext = raf.readSync(4);
        if (ext.length < 4) return null;
        pos += ver == 4 ? _syncSafe(ext, 0) : _be32(ext, 0) + 4;
      }
      var guard = 0;
      // Frames are walked by SEEKING, not by reading the whole tag:
      // art tags run to megabytes and the picture is one frame among
      // many. Only the APIC payload is ever read.
      while (pos + hdrLen <= end && guard < 512) {
        guard++;
        raf.setPositionSync(pos);
        final fh = raf.readSync(hdrLen);
        if (fh.length < hdrLen) return null;
        final idLen = ver == 2 ? 3 : 4;
        final id = String.fromCharCodes(fh.sublist(0, idLen));
        if (id.codeUnitAt(0) == 0) return null; // padding
        final size = ver == 2
            ? ((fh[3] << 16) | (fh[4] << 8) | fh[5])
            : (ver == 4 ? _syncSafe(fh, 4) : _be32(fh, 4));
        if (size <= 0 || size > _maxArt) return null;
        if (id == 'APIC' || id == 'PIC') {
          final payload = raf.readSync(size);
          if (payload.length < size) return null;
          return _id3PicturePayload(Uint8List.fromList(payload), ver == 2);
        }
        pos += hdrLen + size;
      }
      return null;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

EmbeddedArt? _id3PicturePayload(Uint8List p, bool v22) {
  if (p.length < 8) return null;
  var i = 0;
  var mime = '';
  if (v22) {
    // PIC: encoding(1) imageFormat(3) type(1) desc(nul) data
    final fmt = String.fromCharCodes(p.sublist(1, 4)).toLowerCase();
    mime = fmt.contains('png') ? 'image/png' : 'image/jpeg';
    i = 5;
    i = _skipTextField(p, i, p[0]);
  } else {
    final enc = p[0];
    final z = _indexOfZero(p, 1);
    if (z < 0) return null;
    mime = String.fromCharCodes(p.sublist(1, z));
    i = z + 2; // past the terminator and the picture-type byte
    i = _skipTextField(p, i, enc);
  }
  if (i < 0 || i >= p.length) return null;
  var bytes = Uint8List.sublistView(p, i);
  // Safety net across tag variants: if the arithmetic landed on
  // something that is not an image, trust the bytes over the layout
  // and cut at the first real picture signature.
  if (_imageMime(bytes) == null) {
    final k = _indexOfImageMagic(p, 0);
    if (k < 0) return null;
    bytes = Uint8List.sublistView(p, k);
    mime = '';
  }
  if (bytes.length < 64) return null;
  return EmbeddedArt(bytes, mime.isNotEmpty ? mime : _imageMime(bytes)!);
}

/// Skip a text field: 2-byte terminators for UTF-16 encodings.
int _skipTextField(Uint8List p, int i, int enc) {
  if (enc == 1 || enc == 2) {
    while (i + 1 < p.length && !(p[i] == 0 && p[i + 1] == 0)) {
      i += 2;
    }
    return i + 2;
  }
  while (i < p.length && p[i] != 0) {
    i++;
  }
  return i + 1;
}

// --------------------------------------------------------------- FLAC

EmbeddedArt? _flacPicture(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final magic = raf.readSync(4);
      if (magic.length < 4) return null;
      for (var b = 0; b < 64; b++) {
        final head = raf.readSync(4);
        if (head.length < 4) return null;
        final last = (head[0] & 0x80) != 0;
        final type = head[0] & 0x7F;
        final len = (head[1] << 16) | (head[2] << 8) | head[3];
        if (len < 0 || len > _maxArt) return null;
        if (type == 6) {
          final block = raf.readSync(len);
          if (block.length < len) return null;
          return _flacPictureBlock(Uint8List.fromList(block));
        }
        raf.setPositionSync(raf.positionSync() + len);
        if (last) return null;
      }
      return null;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// FLAC PICTURE block: type(4) mimeLen(4) mime descLen(4) desc
/// width(4) height(4) depth(4) colours(4) dataLen(4) data.
/// Ogg/Opus carry the identical structure, base64 in a comment.
EmbeddedArt? _flacPictureBlock(Uint8List b) {
  var i = 4;
  if (i + 4 > b.length) return null;
  final mimeLen = _be32(b, i);
  i += 4;
  if (mimeLen < 0 || mimeLen > 256 || i + mimeLen > b.length) return null;
  final mime = String.fromCharCodes(b.sublist(i, i + mimeLen));
  i += mimeLen;
  if (i + 4 > b.length) return null;
  final descLen = _be32(b, i);
  i += 4;
  if (descLen < 0 || i + descLen > b.length) return null;
  i += descLen;
  if (i + 20 > b.length) return null;
  i += 16; // width, height, depth, colours
  final dataLen = _be32(b, i);
  i += 4;
  if (dataLen <= 0 || dataLen > _maxArt || i + dataLen > b.length) return null;
  final bytes = Uint8List.sublistView(b, i, i + dataLen);
  final sniffed = _imageMime(bytes);
  if (sniffed == null) return null;
  return EmbeddedArt(bytes, mime.isNotEmpty ? mime : sniffed);
}

// ---------------------------------------------------------- Ogg / Opus

EmbeddedArt? _oggPicture(String path) {
  try {
    // One walk of the file for both spellings.
    final comments = vorbisComments(path);
    String? mimeHint;
    for (final c in comments) {
      final eq = c.indexOf('=');
      if (eq <= 0) continue;
      if (c.substring(0, eq).toUpperCase() == 'COVERARTMIME') {
        mimeHint = c.substring(eq + 1).trim();
        break;
      }
    }
    for (final c in comments) {
      final eq = c.indexOf('=');
      if (eq <= 0) continue;
      final key = c.substring(0, eq).toUpperCase();
      if (key != 'METADATA_BLOCK_PICTURE') continue;
      final b64 = c.substring(eq + 1).replaceAll(RegExp(r'\s'), '');
      if (b64.isEmpty) continue;
      try {
        final art = _flacPictureBlock(base64Decode(b64));
        if (art != null) return art;
      } catch (_) {}
    }
    // Legacy escape hatch, pre-PICTURE comment tags.
    for (final c in comments) {
      final eq = c.indexOf('=');
      if (eq <= 0) continue;
      if (c.substring(0, eq).toUpperCase() != 'COVERART') continue;
      final b64 = c.substring(eq + 1).replaceAll(RegExp(r'\s'), '');
      if (b64.isEmpty) continue;
      final bytes = base64Decode(b64);
      final sniffed = _imageMime(bytes);
      if (sniffed == null) return null;
      return EmbeddedArt(bytes, mimeHint ?? sniffed);
    }
    return null;
  } catch (_) {
    return null;
  }
}

// -------------------------------------------------------------- MP4

EmbeddedArt? _mp4Picture(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final fileLen = raf.lengthSync();
      if (fileLen <= 0) return null;
      // moov -> udta -> meta -> ilst, same descent tag_lyrics uses.
      final want = ['moov', 'udta', 'meta', 'ilst'];
      final ends = <int>[fileLen];
      var pos = 0;
      var depth = 0;
      var guard = 0;
      List<int>? ilst;
      while (pos + 8 <= ends.last && guard < 4096) {
        guard++;
        raf.setPositionSync(pos);
        final head = raf.readSync(8);
        if (head.length < 8) return null;
        var size = _be32(head, 0);
        final type = String.fromCharCodes(head.sublist(4, 8));
        var headerLen = 8;
        if (size == 1) {
          final ext = raf.readSync(8);
          if (ext.length < 8) return null;
          size = _be64(ext);
          headerLen = 16;
        }
        if (size <= 0) return null;
        final end = pos + size;
        if (depth < want.length && type == want[depth]) {
          ends.add(end);
          depth++;
          pos += headerLen + (type == 'meta' ? 4 : 0);
          if (depth == want.length) {
            ilst = [pos, end];
            break;
          }
          continue;
        }
        pos = end;
        while (ends.length > 1 && pos >= ends.last) {
          ends.removeLast();
          depth--;
        }
      }
      if (ilst == null) return null;
      var cpos = ilst[0];
      final cend = ilst[1];
      guard = 0;
      while (cpos + 8 <= cend && guard < 128) {
        guard++;
        raf.setPositionSync(cpos);
        final head = raf.readSync(8);
        if (head.length < 8) return null;
        final size = _be32(head, 0);
        final type = String.fromCharCodes(head.sublist(4, 8));
        if (size < 8) return null;
        if (type == 'covr') {
          final art = _mp4Covr(raf, cpos + 8, cpos + size);
          if (art != null) return art;
          return null;
        }
        cpos += size;
      }
      return null;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// Inside `covr` live one or more `data` atoms. The image starts at a
/// JPEG/PNG signature; the 4-byte type indicator before it varies
/// (0x0D jpeg / 0x0E png, sometimes with a locale field), so trusting
/// the magic beats trusting the layout.
EmbeddedArt? _mp4Covr(RandomAccessFile raf, int start, int end) {
  var dpos = start;
  var guard = 0;
  while (dpos + 8 <= end && guard < 16) {
    guard++;
    raf.setPositionSync(dpos);
    final dh = raf.readSync(8);
    if (dh.length < 8) return null;
    final dsize = _be32(dh, 0);
    final dtype = String.fromCharCodes(dh.sublist(4, 8));
    if (dsize < 16 || dpos + dsize > end || dsize > _maxArt) return null;
    if (dtype == 'data') {
      raf.setPositionSync(dpos);
      final atom = Uint8List.fromList(raf.readSync(dsize));
      final k = _indexOfImageMagic(atom, 0);
      if (k < 0) return null;
      final bytes = Uint8List.sublistView(atom, k);
      final mime = _imageMime(bytes);
      if (mime == null) return null;
      return EmbeddedArt(bytes, mime);
    }
    dpos += dsize;
  }
  return null;
}

// ------------------------------------------------------------ helpers

int _be32(Uint8List b, int i) => i + 4 > b.length
    ? 0
    : ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]);

int _be64(Uint8List b) {
  if (b.length < 8) return 0;
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | b[i];
  }
  return v;
}

int _syncSafe(Uint8List b, int i) {
  if (i + 4 > b.length) return 0;
  return ((b[i] & 0x7F) << 21) |
      ((b[i + 1] & 0x7F) << 14) |
      ((b[i + 2] & 0x7F) << 7) |
      (b[i + 3] & 0x7F);
}

int _indexOfZero(Uint8List b, int from) {
  for (var i = from; i < b.length; i++) {
    if (b[i] == 0) return i;
  }
  return -1;
}

/// First JPEG (FFD8FF) or PNG (89504E47) signature at or after [from].
int _indexOfImageMagic(Uint8List b, int from) {
  for (var i = from; i + 3 < b.length; i++) {
    if (b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF) return i;
    if (b[i] == 0x89 &&
        b[i + 1] == 0x50 &&
        b[i + 2] == 0x4E &&
        b[i + 3] == 0x47) {
      return i;
    }
  }
  return -1;
}

String? _imageMime(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 4 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  return null;
}

/// File-art previews that survive restarts live in
/// art_previews.dart; this file stays the pure container reader.
