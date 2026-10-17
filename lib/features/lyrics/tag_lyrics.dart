import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/models.dart';

/// Embedded lyrics, read straight from file tags in pure Dart: no new
/// package, no native work, no extra permissions (Song.path is already
/// ours). MP3 ID3v2 USLT/SYLT (plus v2.2 ULT), FLAC/OGG/Opus Vorbis
/// comments, M4A ilst lyrics. Bounded reads, never throws - failure is
/// just LyricDoc.none() and the pipeline moves on to LRCLib.
LyricDoc readEmbeddedLyrics(String path) {
  if (path.isEmpty) return const LyricDoc();
  try {
    if (!File(path).existsSync()) return const LyricDoc();
  } catch (_) {
    return const LyricDoc();
  }
  final lower = path.toLowerCase();
  // MP3 (and friends carrying ID3): USLT/SYLT first.
  final id3 = _readId3(path);
  if (id3.hasSynced || id3.hasPlain) return id3;
  if (lower.endsWith('.flac')) {
    final doc = _readFlacComment(path);
    if (doc.hasSynced || doc.hasPlain) return doc;
  } else if (lower.endsWith('.ogg') ||
      lower.endsWith('.oga') ||
      lower.endsWith('.opus')) {
    final doc = _readOggComment(path);
    if (doc.hasSynced || doc.hasPlain) return doc;
  } else if (lower.endsWith('.m4a') ||
      lower.endsWith('.mp4') ||
      lower.endsWith('.m4b')) {
    final doc = _readM4aLyrics(path);
    if (doc.hasSynced || doc.hasPlain) return doc;
  }
  return id3;
}

LyricDoc _readId3(String path) {
  try {
    final file = File(path);
    final raf = file.openSync();
    try {
      final head = raf.readSync(10);
      if (head.length < 10 ||
          head[0] != 0x49 ||
          head[1] != 0x44 ||
          head[2] != 0x33) {
        return const LyricDoc(); // No ID3v2 tag.
      }
      final ver = head[3];
      if (ver != 2 && ver != 3 && ver != 4) return const LyricDoc();
      final flags = head[5];
      final tagSize = _syncSafe(head, 6);
      if (tagSize <= 0 || tagSize > 4 * 1024 * 1024) return const LyricDoc();
      final tag = raf.readSync(tagSize);
      if (tag.length < tagSize) return const LyricDoc();
      if (ver == 2) return _parseTag22(tag);
      return _parseTag(tag, ver, flags);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return const LyricDoc();
  }
}

/// ID3v2.2: 3-char frame ids, 3-byte sizes. ULT body matches USLT.
LyricDoc _parseTag22(Uint8List tag) {
  var pos = 0;
  String? plain;
  while (pos + 6 <= tag.length) {
    if (tag[pos] == 0) break;
    final id = String.fromCharCodes(tag.sublist(pos, pos + 3));
    final size = (tag[pos + 3] << 16) | (tag[pos + 4] << 8) | tag[pos + 5];
    final start = pos + 6;
    if (size <= 0 || start + size > tag.length) break;
    final data = tag.sublist(start, start + size);
    pos = start + size;
    if (id == 'ULT' && plain == null) {
      plain = _parseUslt(data);
    }
  }
  if (plain != null && plain.trim().isNotEmpty) {
    return LyricDoc(plain: plain, source: LyricSource.embedded);
  }
  return const LyricDoc();
}

LyricDoc _parseTag(Uint8List tag, int ver, int flags) {
  var pos = 0;
  // Extended header: v2.3 size is plain int, v2.4 syncsafe.
  if ((flags & 0x40) != 0) {
    if (tag.length < 4) return const LyricDoc();
    final ext = ver == 4
        ? _syncSafe(tag, 0)
        : ((tag[0] << 24) | (tag[1] << 16) | (tag[2] << 8) | tag[3]);
    pos = ext;
  }
  final unsyncWhole = ver == 3 && (flags & 0x80) != 0;
  String? plain;
  String? synced;
  while (pos + 10 <= tag.length) {
    if (tag[pos] == 0) break; // Padding.
    final id = String.fromCharCodes(tag.sublist(pos, pos + 4));
    final size = ver == 4
        ? _syncSafe(tag, pos + 4)
        : ((tag[pos + 4] << 24) |
              (tag[pos + 5] << 16) |
              (tag[pos + 6] << 8) |
              tag[pos + 7]);
    final frameFlags = (tag[pos + 8] << 8) | tag[pos + 9];
    final start = pos + 10;
    if (size <= 0 || start + size > tag.length) break;
    var data = tag.sublist(start, start + size);
    pos = start + size;
    if (unsyncWhole || (ver == 4 && (frameFlags & 0x02) != 0)) {
      data = _deunsync(data);
    }
    if (id == 'USLT' && plain == null) {
      plain = _parseUslt(data);
    } else if (id == 'SYLT' && synced == null) {
      synced = _parseSylt(data);
    }
    if (plain != null && synced != null) break;
  }
  if (synced != null && synced.trim().isNotEmpty) {
    return LyricDoc(syncedLrc: synced, source: LyricSource.embedded);
  }
  if (plain != null && plain.trim().isNotEmpty) {
    return LyricDoc(plain: plain, source: LyricSource.embedded);
  }
  return const LyricDoc();
}

String? _parseUslt(Uint8List data) {
  if (data.length < 5) return null;
  final enc = data[0];
  final textStart = _skipTerminator(data, 4, enc);
  if (textStart >= data.length) return null;
  return _decode(data.sublist(textStart), enc)?.trim();
}

String? _parseSylt(Uint8List data) {
  if (data.length < 7) return null;
  final enc = data[0];
  // data[1..3] language, data[4] timestamp format (1 = ms).
  if (data[4] != 1) return null;
  var pos = _skipTerminator(data, 6, enc);
  final out = StringBuffer();
  while (pos + 4 < data.length) {
    // Entry: terminated text + 4-byte big-endian ms.
    var end = pos;
    if (enc == 0 || enc == 3) {
      while (end < data.length && data[end] != 0) {
        end++;
      }
    } else {
      while (end + 1 < data.length && !(data[end] == 0 && data[end + 1] == 0)) {
        end += 2;
      }
    }
    if (end + 4 >= data.length) break;
    final text = _decode(data.sublist(pos, end), enc)?.trim() ?? '';
    final ms =
        (data[end] << 24) |
        (data[end + 1] << 16) |
        (data[end + 2] << 8) |
        data[end + 3];
    pos = end + 4 + (enc == 0 || enc == 3 ? 1 : 2);
    if (text.isEmpty) continue;
    out.writeln('${_lrcStamp(ms)}$text');
  }
  final lrc = out.toString().trim();
  return lrc.isEmpty ? null : lrc;
}

String _lrcStamp(int ms) {
  if (ms < 0) ms = 0;
  final mm = (ms ~/ 60000).toString().padLeft(2, '0');
  final ss = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
  final cc = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
  return '[$mm:$ss.$cc]';
}

int _syncSafe(List<int> b, int at) =>
    ((b[at] & 0x7F) << 21) |
    ((b[at + 1] & 0x7F) << 14) |
    ((b[at + 2] & 0x7F) << 7) |
    (b[at + 3] & 0x7F);

Uint8List _deunsync(Uint8List data) {
  final out = <int>[];
  for (var i = 0; i < data.length; i++) {
    out.add(data[i]);
    if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) {
      i++;
    }
  }
  return Uint8List.fromList(out);
}

int _skipTerminator(Uint8List data, int from, int enc) {
  if (enc == 0 || enc == 3) {
    while (from < data.length && data[from] != 0) {
      from++;
    }
    return from + 1;
  }
  while (from + 1 < data.length && !(data[from] == 0 && data[from + 1] == 0)) {
    from += 2;
  }
  return from + 2;
}

String? _decode(Uint8List data, int enc) {
  try {
    switch (enc) {
      case 0:
        return latin1.decode(data);
      case 3:
        return utf8.decode(data, allowMalformed: true);
      case 1:
      case 2:
        return _decodeUtf16(data, enc == 2);
    }
  } catch (_) {}
  return null;
}

String _decodeUtf16(Uint8List data, bool bigEndian) {
  var i = 0;
  var be = bigEndian;
  if (data.length >= 2) {
    if (data[0] == 0xFE && data[1] == 0xFF) {
      be = true;
      i = 2;
    } else if (data[0] == 0xFF && data[1] == 0xFE) {
      be = false;
      i = 2;
    }
  }
  final out = StringBuffer();
  // Collect units, then fold surrogate pairs.
  final codeUnits = <int>[];
  for (; i + 1 < data.length; i += 2) {
    codeUnits.add(
      be ? (data[i] << 8) | data[i + 1] : data[i] | (data[i + 1] << 8),
    );
  }
  for (var j = 0; j < codeUnits.length; j++) {
    final u = codeUnits[j];
    if (u >= 0xD800 && u <= 0xDBFF && j + 1 < codeUnits.length) {
      final lo = codeUnits[j + 1];
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        out.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00));
        j++;
        continue;
      }
    }
    if (u == 0) continue;
    out.writeCharCode(u);
  }
  return out.toString();
}

/// Embedded genre, same pure-Dart discipline as lyrics: ID3 TCON
/// (plus v2.2 TCO), Vorbis GENRE, M4A (c)gen string. Numeric ID3
/// wrappers ("(4)") resolve through the v1 table. Null = absent.
/// Bounded reads, never throws.
String? readEmbeddedGenre(String path) {
  if (path.isEmpty) return null;
  try {
    if (!File(path).existsSync()) return null;
  } catch (_) {
    return null;
  }
  try {
    final head = File(path).openSync();
    try {
      final magic = head.readSync(4);
      if (magic.length == 4 &&
          magic[0] == 0x49 &&
          magic[1] == 0x44 &&
          magic[2] == 0x33) {
        return _id3Genre(path);
      }
    } finally {
      head.closeSync();
    }
  } catch (_) {}
  final lower = path.toLowerCase();
  try {
    if (lower.endsWith('.flac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.oga') ||
        lower.endsWith('.opus')) {
      return _vorbisGenre(path);
    }
    if (lower.endsWith('.m4a') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.m4b')) {
      return _m4aGenre(path);
    }
    if (lower.endsWith('.mp3')) return _id3Genre(path);
  } catch (_) {}
  return null;
}

String? _cleanGenre(String? raw) {
  if (raw == null) return null;
  var t = raw.trim();
  if (t.isEmpty) return null;
  // Numeric "(4)Eurodisco" wrappers: prefer the text, else the table.
  final num = RegExp(r'^\((\d+)\)\s*(.*)$').firstMatch(t);
  if (num != null) {
    final rest = (num.group(2) ?? '').trim();
    if (rest.isNotEmpty) return rest;
    final idx = int.tryParse(num.group(1) ?? '');
    if (idx != null && idx >= 0 && idx < _id3v1.length) {
      return _id3v1[idx];
    }
    return null;
  }
  if (RegExp(r'^\d+$').hasMatch(t)) {
    final idx = int.tryParse(t);
    if (idx != null && idx >= 0 && idx < _id3v1.length) {
      return _id3v1[idx];
    }
    return null;
  }
  return t.length > 48 ? null : t;
}

String? _id3Genre(String path) {
  try {
    final file = File(path);
    final raf = file.openSync();
    try {
      final head = raf.readSync(10);
      if (head.length < 10 ||
          head[0] != 0x49 ||
          head[1] != 0x44 ||
          head[2] != 0x33) {
        return null;
      }
      final ver = head[3];
      if (ver != 2 && ver != 3 && ver != 4) return null;
      final flags = head[5];
      final tagSize = _syncSafe(head, 6);
      if (tagSize <= 0 || tagSize > 4 * 1024 * 1024) return null;
      final tag = raf.readSync(tagSize);
      if (tag.length < tagSize) return null;
      if (ver == 2) return _scanGenre22(tag);
      var pos = 0;
      if ((flags & 0x40) != 0) {
        if (tag.length < 4) return null;
        pos = ver == 4
            ? _syncSafe(tag, 0)
            : ((tag[0] << 24) | (tag[1] << 16) | (tag[2] << 8) | tag[3]);
      }
      final unsyncWhole = ver == 3 && (flags & 0x80) != 0;
      while (pos + 10 <= tag.length) {
        if (tag[pos] == 0) break;
        final id = String.fromCharCodes(tag.sublist(pos, pos + 4));
        final size = ver == 4
            ? _syncSafe(tag, pos + 4)
            : ((tag[pos + 4] << 24) |
                (tag[pos + 5] << 16) |
                (tag[pos + 6] << 8) |
                tag[pos + 7]);
        final frameFlags = (tag[pos + 8] << 8) | tag[pos + 9];
        final start = pos + 10;
        if (size <= 0 || start + size > tag.length) break;
        var data = tag.sublist(start, start + size);
        pos = start + size;
        if (unsyncWhole || (ver == 4 && (frameFlags & 0x02) != 0)) {
          data = _deunsync(data);
        }
        if (id == 'TCON' && data.isNotEmpty) {
          final enc = data[0];
          final g = _cleanGenre(_decode(data.sublist(1), enc));
          if (g != null) return g;
        }
      }
      return null;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

String? _scanGenre22(Uint8List tag) {
  var pos = 0;
  while (pos + 6 <= tag.length) {
    if (tag[pos] == 0) break;
    final id = String.fromCharCodes(tag.sublist(pos, pos + 3));
    final size = (tag[pos + 3] << 16) | (tag[pos + 4] << 8) | tag[pos + 5];
    final start = pos + 6;
    if (size <= 0 || start + size > tag.length) break;
    final data = tag.sublist(start, start + size);
    pos = start + size;
    if (id == 'TCO' && data.isNotEmpty) {
      final g = _cleanGenre(_decode(data.sublist(1), data[0]));
      if (g != null) return g;
    }
  }
  return null;
}

String? _vorbisGenre(String path) {
  for (final entry in vorbisComments(path)) {
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    if (entry.substring(0, eq).trim().toUpperCase() == 'GENRE') {
      final g = _cleanGenre(entry.substring(eq + 1));
      if (g != null) return g;
    }
  }
  return null;
}

/// Shared Vorbis comment entry reader (KEY=value strings). Public
/// because the embedded-art reader wants the same walk for Ogg/Opus
/// pictures (`METADATA_BLOCK_PICTURE` is just another comment).
List<String> vorbisComments(String path) {
  final out = <String>[];
  try {
    final lower = path.toLowerCase();
    if (lower.endsWith('.flac')) {
      final raf = File(path).openSync();
      try {
        final magic = raf.readSync(4);
        if (magic.length < 4 ||
            magic[0] != 0x66 ||
            magic[1] != 0x4C ||
            magic[2] != 0x61 ||
            magic[3] != 0x43) {
          return out;
        }
        for (var b = 0; b < 64; b++) {
          final head = raf.readSync(4);
          if (head.length < 4) break;
          final last = (head[0] & 0x80) != 0;
          final type = head[0] & 0x7F;
          final len = (head[1] << 16) | (head[2] << 8) | head[3];
          if (len < 0 || len > 1024 * 1024) break;
          if (type == 4) {
            final block = raf.readSync(len);
            if (block.length < len) break;
            return _commentEntries(block);
          }
          raf.setPositionSync(raf.positionSync() + len);
          if (last) break;
        }
      } finally {
        raf.closeSync();
      }
      return out;
    }
    final raf = File(path).openSync();
    try {
      final packets = <List<int>>[];
      var current = <int>[];
      for (var p = 0; p < 200; p++) {
        final head = raf.readSync(27);
        if (head.length < 27) break;
        if (head[0] != 0x4F ||
            head[1] != 0x67 ||
            head[2] != 0x67 ||
            head[3] != 0x53) {
          break;
        }
        final nseg = head[26];
        final table = raf.readSync(nseg);
        if (table.length < nseg) break;
        var payload = 0;
        for (final s in table) {
          payload += s;
        }
        final data = raf.readSync(payload);
        if (data.length < payload) break;
        var at = 0;
        for (final s in table) {
          current.addAll(data.sublist(at, at + s));
          at += s;
          if (s < 255) {
            packets.add(current);
            current = <int>[];
          }
        }
        if (packets.length >= 3) break;
      }
      if (packets.length > 1) {
        // Vorbis packets start with `\x01vorbis` (7 bytes to skip);
        // Opus packets start with `OpusTags` and `_commentEntries`
        // skips that itself. Hardcoding 7 put Opus one byte off, so
        // its comments never parsed at all.
        final pkt = packets[1];
        final isOpus = pkt.length >= 8 &&
            String.fromCharCodes(pkt.sublist(0, 8)) == 'OpusTags';
        return _commentEntries(
            Uint8List.fromList(isOpus ? pkt : pkt.skip(7).toList()));
      }
    } finally {
      raf.closeSync();
    }
  } catch (_) {}
  return out;
}

List<String> _commentEntries(Uint8List body) {
  final out = <String>[];
  try {
    var pos = 0;
    int u32() {
      final v =
          body[pos] |
          (body[pos + 1] << 8) |
          (body[pos + 2] << 16) |
          (body[pos + 3] << 24);
      pos += 4;
      return v;
    }

    if (body.length < 8) return out;
    // OpusTags skips an 8-byte magic first.
    if (body.length >= 12 &&
        String.fromCharCodes(body.sublist(0, 8)) == 'OpusTags') {
      pos = 8;
    }
    final vendorLen = u32();
    if (vendorLen < 0 || vendorLen > body.length) return out;
    pos += vendorLen;
    if (pos + 4 > body.length) return out;
    final count = u32();
    if (count < 0 || count > 512) return out;
    for (var i = 0; i < count; i++) {
      if (pos + 4 > body.length) break;
      final len = u32();
      if (len < 0 || len > 512 * 1024 || pos + len > body.length) break;
      out.add(
        utf8.decode(body.sublist(pos, pos + len), allowMalformed: true),
      );
      pos += len;
    }
  } catch (_) {}
  return out;
}

String? _m4aGenre(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final fileLen = raf.lengthSync();
      if (fileLen <= 0 || fileLen > 1024 * 1024 * 1024) return null;
      // moov -> udta -> meta -> ilst, then (c)gen data payload.
      final want = ['moov', 'udta', 'meta', 'ilst'];
      final ends = <int>[fileLen];
      var pos = 0;
      var depth = 0;
      var guard = 0;
      List<int>? ilst;
      var cend = 0;
      while (pos + 8 <= ends.last && guard < 1024) {
        guard++;
        raf.setPositionSync(pos);
        final head = raf.readSync(8);
        if (head.length < 8) break;
        var size = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        final type = String.fromCharCodes(head.sublist(4, 8));
        var headerLen = 8;
        if (size == 1) break;
        if (size <= 0) break;
        final end = pos + size;
        if (depth < want.length && type == want[depth]) {
          ends.add(end);
          depth++;
          pos += headerLen + (type == 'meta' ? 4 : 0);
          if (depth == want.length) {
            ilst = [pos, end];
            cend = end;
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
      guard = 0;
      while (cpos + 8 <= cend && guard < 256) {
        guard++;
        raf.setPositionSync(cpos);
        final head = raf.readSync(8);
        if (head.length < 8) break;
        final size =
            (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        if (size <= 8 || cpos + size > cend) break;
        final isGen =
            head[4] == 0xA9 &&
            head[5] == 0x67 &&
            head[6] == 0x65 &&
            head[7] == 0x6E;
        if (isGen) {
          final dataHead = raf.readSync(16);
          if (dataHead.length < 16) break;
          final payloadLen = size - 8 - 16;
          if (payloadLen <= 0 || payloadLen > 1024) break;
          final payload = raf.readSync(payloadLen);
          final text =
              utf8.decode(payload, allowMalformed: true).trim().replaceAll(
                    RegExp(r'[^\x20-\x7E\u00A0-\uFFFF]'),
                    '',
                  ).trim();
          return _cleanGenre(text.isEmpty ? null : text);
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

/// ID3v1 genre table (0-79 + common Winamp extensions to 147).
const _id3v1 = [
  'Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge',
  'Hip-Hop', 'Jazz', 'Metal', 'New Age', 'Oldies', 'Other', 'Pop', 'R&B',
  'Rap', 'Reggae', 'Rock', 'Techno', 'Industrial', 'Alternative', 'Ska',
  'Death Metal', 'Pranks', 'Soundtrack', 'Euro-Techno', 'Ambient',
  'Trip-Hop', 'Vocal', 'Jazz+Funk', 'Fusion', 'Trance', 'Classical',
  'Instrumental', 'Acid', 'House', 'Game', 'Sound Clip', 'Gospel', 'Noise',
  'AlternRock', 'Bass', 'Soul', 'Punk', 'Space', 'Meditative',
  'Instrumental Pop', 'Instrumental Rock', 'Ethnic', 'Gothic', 'Darkwave',
  'Techno-Industrial', 'Electronic', 'Pop-Folk', 'Eurodance', 'Dream',
  'Southern Rock', 'Comedy', 'Cult', 'Gangsta', 'Top 40', 'Christian Rap',
  'Pop/Funk', 'Jungle', 'Native American', 'Cabaret', 'New Wave',
  'Psychadelic', 'Rave', 'Showtunes', 'Trailer', 'Lo-Fi', 'Tribal',
  'Acid Punk', 'Acid Jazz', 'Polka', 'Retro', 'Musical', 'Rock & Roll',
  'Hard Rock', 'Folk', 'Folk-Rock', 'National Folk', 'Swing',
  'Fast Fusion', 'Bebob', 'Latin', 'Revival', 'Celtic', 'Bluegrass',
  'Avantgarde', 'Gothic Rock', 'Progressive Rock', 'Psychedelic Rock',
  'Symphonic Rock', 'Slow Rock', 'Big Band', 'Chorus', 'Easy Listening',
  'Acoustic', 'Humour', 'Speech', 'Chanson', 'Opera', 'Chamber Music',
  'Sonata', 'Symphony', 'Booty Bass', 'Primus', 'Porn Groove', 'Satire',
  'Slow Jam', 'Club', 'Tango', 'Samba', 'Folklore', 'Ballad',
  'Power Ballad', 'Rhythmic Soul', 'Freestyle', 'Duet', 'Punk Rock',
  'Drum Solo', 'A Cappella', 'Euro-House', 'Dance Hall', 'Goa',
  'Drum & Bass', 'Club-House', 'Hardcore', 'Terror', 'Indie', 'BritPop',
  'Afro-Punk', 'Polsk Punk', 'Beat', 'Christian Gangsta Rap',
  'Heavy Metal', 'Black Metal', 'Crossover', 'Contemporary Christian',
  'Christian Rock', 'Merengue', 'Salsa', 'Thrash Metal', 'Anime', 'JPop',
  'Synthpop', 'Abstract', 'Art Rock', 'Baroque', 'Bhangra', 'Big Beat',
  'Breakbeat', 'Chillout', 'Downtempo', 'Dub', 'EBM', 'Eclectic',
  'Electro', 'Electroclash', 'Emo', 'Experimental', 'Garage', 'Global',
  'IDM', 'Illbient', 'Industro-Goth', 'Jam Band', 'Krautrock',
  'Leftfield', 'Lounge', 'Math Rock', 'New Romantic', 'Nu-Breakz',
  'Post-Punk', 'Post-Rock', 'Psytrance', 'Shoegaze', 'Space Rock',
  'Trop Rock', 'World Music', 'Neoclassical', 'Audiobook', 'Audio Theatre',
  'Neue Deutsche Welle', 'Podcast', 'Indie Rock', 'G-Funk', 'Dubstep',
  'Garage Rock', 'Psybient',
];

/// Vorbis comments (FLAC): fLaC marker, then metadata blocks; type 4
/// is the comment list. Shared field rule with OGG/Opus below.
LyricDoc _readFlacComment(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final magic = raf.readSync(4);
      if (magic.length < 4 ||
          magic[0] != 0x66 ||
          magic[1] != 0x4C ||
          magic[2] != 0x61 ||
          magic[3] != 0x43) {
        return const LyricDoc();
      }
      for (var b = 0; b < 64; b++) {
        final head = raf.readSync(4);
        if (head.length < 4) break;
        final last = (head[0] & 0x80) != 0;
        final type = head[0] & 0x7F;
        final len = (head[1] << 16) | (head[2] << 8) | head[3];
        if (len < 0 || len > 1024 * 1024) break;
        if (type == 4) {
          final block = raf.readSync(len);
          if (block.length < len) break;
          return _vorbisCommentDoc(block);
        }
        raf.setPositionSync(raf.positionSync() + len);
        if (last) break;
      }
      return const LyricDoc();
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return const LyricDoc();
  }
}

/// OGG container (Vorbis + Opus): page walk, packet reassembly, then
/// the comment packet. Bounded (200 pages max).
LyricDoc _readOggComment(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final packets = <List<int>>[];
      var current = <int>[];
      for (var p = 0; p < 200; p++) {
        final head = raf.readSync(27);
        if (head.length < 27) break;
        if (head[0] != 0x4F ||
            head[1] != 0x67 ||
            head[2] != 0x67 ||
            head[3] != 0x53) {
          break;
        }
        final nseg = head[26];
        final table = raf.readSync(nseg);
        if (table.length < nseg) break;
        var payload = 0;
        for (final s in table) {
          payload += s;
        }
        final data = raf.readSync(payload);
        if (data.length < payload) break;
        var at = 0;
        for (final s in table) {
          current.addAll(data.sublist(at, at + s));
          at += s;
          if (s < 255) {
            packets.add(current);
            current = <int>[];
          }
        }
        if (packets.length >= 3) break;
      }
      if (packets.isEmpty) return const LyricDoc();
      final p0 = packets[0];
      final isOpus =
          p0.length >= 8 &&
          p0[0] == 0x4F &&
          p0[1] == 0x70 &&
          p0[2] == 0x75 &&
          p0[3] == 0x73;
      final isVorbis =
          p0.length >= 7 &&
          p0[0] == 0x01 &&
          p0[1] == 0x76 &&
          p0[2] == 0x6F &&
          p0[3] == 0x72 &&
          p0[4] == 0x62 &&
          p0[5] == 0x69 &&
          p0[6] == 0x73;
      for (final packet in packets.skip(1)) {
        if (isOpus &&
            packet.length > 8 &&
            String.fromCharCodes(packet.sublist(0, 8)) == 'OpusTags') {
          return _vorbisCommentDoc(Uint8List.fromList(packet.sublist(8)));
        }
        if (isVorbis &&
            packet.length > 7 &&
            packet[0] == 0x03 &&
            String.fromCharCodes(packet.sublist(1, 7)) == 'vorbis') {
          return _vorbisCommentDoc(Uint8List.fromList(packet.sublist(7)));
        }
      }
      return const LyricDoc();
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return const LyricDoc();
  }
}

/// Vorbis comment body: vendor + count + KEY=value entries (LE32,
/// UTF-8). LYRICS-family keys win; timestamped text parses as LRC.
LyricDoc _vorbisCommentDoc(Uint8List body) {
  try {
    var pos = 0;
    int u32() {
      final v =
          body[pos] |
          (body[pos + 1] << 8) |
          (body[pos + 2] << 16) |
          (body[pos + 3] << 24);
      pos += 4;
      return v;
    }

    if (body.length < 8) return const LyricDoc();
    final vendorLen = u32();
    if (vendorLen < 0 || vendorLen > body.length) return const LyricDoc();
    pos += vendorLen;
    if (pos + 4 > body.length) return const LyricDoc();
    final count = u32();
    if (count < 0 || count > 512) return const LyricDoc();
    final found = <String>[];
    for (var i = 0; i < count; i++) {
      if (pos + 4 > body.length) break;
      final len = u32();
      if (len < 0 || len > 512 * 1024 || pos + len > body.length) break;
      final entry = utf8.decode(
        body.sublist(pos, pos + len),
        allowMalformed: true,
      );
      pos += len;
      final eq = entry.indexOf('=');
      if (eq <= 0) continue;
      final key = entry.substring(0, eq).trim().toUpperCase();
      if (key == 'LYRICS' ||
          key == 'UNSYNCED LYRICS' ||
          key == 'UNSYNCEDLYRICS' ||
          key == 'UNSYCHRONISED LYRICS') {
        found.add(entry.substring(eq + 1));
      }
    }
    if (found.isEmpty) return const LyricDoc();
    final text = found.join('\n\n').trim();
    if (text.isEmpty) return const LyricDoc();
    if (_looksTimed(text)) {
      return LyricDoc(syncedLrc: text, source: LyricSource.embedded);
    }
    return LyricDoc(plain: text, source: LyricSource.embedded);
  } catch (_) {
    return const LyricDoc();
  }
}

bool _looksTimed(String text) {
  var hits = 0;
  for (final line in text.split('\n')) {
    if (RegExp(r'^\s*\[\d{1,3}:\d{2}([.:]\d{1,3})?\]').hasMatch(line)) {
      hits++;
      if (hits >= 2) return true;
    }
  }
  return false;
}

/// M4A/MP4: box walk moov -> udta -> meta -> ilst -> (c)lyr -> data.
/// Sizes are big-endian; meta has a 4-byte version/flags prefix.
LyricDoc _readM4aLyrics(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final fileLen = raf.lengthSync();
      if (fileLen <= 0 || fileLen > 1024 * 1024 * 1024) {
        return const LyricDoc();
      }
      List<int>? ilst;
      // Descend only along moov -> udta -> meta -> ilst, tracking
      // container ends so siblings (trak...) scan past correctly.
      final want = ['moov', 'udta', 'meta', 'ilst'];
      final ends = <int>[fileLen];
      var pos = 0;
      var depth = 0;
      var guard = 0;
      while (pos + 8 <= ends.last && guard < 1024) {
        guard++;
        raf.setPositionSync(pos);
        final head = raf.readSync(8);
        if (head.length < 8) break;
        var size = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        final type = String.fromCharCodes(head.sublist(4, 8));
        var headerLen = 8;
        if (size == 1) {
          final ext = raf.readSync(8);
          if (ext.length < 8) break;
          size = 0;
          for (var i = 0; i < 8; i++) {
            size = (size << 8) | ext[i];
          }
          headerLen = 16;
        }
        if (size <= 0) break;
        final end = pos + size;
        if (depth < want.length && type == want[depth]) {
          ends.add(end);
          depth++;
          // meta carries a 4-byte version/flags prefix after header.
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
      if (ilst == null) return const LyricDoc();
      var cpos = ilst[0];
      final cend = ilst[1];
      guard = 0;
      while (cpos + 8 <= cend && guard < 256) {
        guard++;
        raf.setPositionSync(cpos);
        final head = raf.readSync(8);
        if (head.length < 8) break;
        final size =
            (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        if (size <= 8 || cpos + size > cend) break;
        final isLyr =
            head[4] == 0xA9 &&
            head[5] == 0x6C &&
            head[6] == 0x79 &&
            head[7] == 0x72;
        if (isLyr) {
          final dataHead = raf.readSync(16);
          if (dataHead.length < 16) break;
          final payloadLen = size - 8 - 16;
          if (payloadLen <= 0 || payloadLen > 512 * 1024) break;
          final payload = raf.readSync(payloadLen);
          final text = utf8.decode(payload, allowMalformed: true).trim();
          if (text.isEmpty) return const LyricDoc();
          if (_looksTimed(text)) {
            return LyricDoc(syncedLrc: text, source: LyricSource.embedded);
          }
          return LyricDoc(plain: text, source: LyricSource.embedded);
        }
        cpos += size;
      }
      return const LyricDoc();
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return const LyricDoc();
  }
}
