import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/log.dart';
import '../../lyrics/tag_lyrics.dart';

/// Every text tag a file carries, canonicalised to one vocabulary so
/// ID3, Vorbis and MP4 can all be shown by the same UI.
///
/// Keys (`kTitle`, `kTrack`, ...) are stable and lowercase; values are
/// display strings already split where the format packs two numbers
/// into one ("3/12" -> track 3 of 12).
///
/// Mirrors the walks in tag_lyrics.dart and embedded_art.dart. That is
/// three container walkers in Dart now: fine for reading, worth
/// consolidating when the Doctor's library-wide pass moves to Rust.
class TagFields {
  final Map<String, String> values;
  final String container;
  const TagFields(this.values, this.container);

  bool get isEmpty => values.isEmpty;
  String? operator [](String key) {
    final v = values[key];
    return v == null || v.isEmpty ? null : v;
  }

  /// "7 / 12" when a total is known, otherwise just "7".
  String? numbered(String key, String totalKey) {
    final n = this[key];
    if (n == null) return null;
    final t = this[totalKey];
    return t == null ? n : '$n / $t';
  }
}

// Canonical keys.
const kTitle = 'title';
const kArtist = 'artist';
const kAlbumArtist = 'albumArtist';
const kAlbum = 'album';
const kTrack = 'track';
const kTrackTotal = 'trackTotal';
const kDisc = 'disc';
const kDiscTotal = 'discTotal';
const kDate = 'date';
const kGenre = 'genre';
const kComposer = 'composer';
const kLyricist = 'lyricist';
const kIsrc = 'isrc';
const kLabel = 'label';
const kCatalogNumber = 'catalogNumber';
const kBarcode = 'barcode';
const kCopyright = 'copyright';
const kBpm = 'bpm';
const kKey = 'key';
const kLanguage = 'language';
const kComment = 'comment';
const kEncoder = 'encoder';
const kCompilation = 'compilation';
const kReleaseType = 'releaseType';

/// Labels for the UI, in a deliberate reading order: what the track is,
/// then who made it, then the catalogue facts.
const tagFieldOrder = <String, String>{
  kTitle: 'Title',
  kArtist: 'Artist',
  kAlbumArtist: 'Album artist',
  kAlbum: 'Album',
  kTrack: 'Track',
  kTrackTotal: 'Total tracks',
  kDisc: 'Disc',
  kDiscTotal: 'Total discs',
  kDate: 'Date',
  kGenre: 'Genre',
  kComposer: 'Composer',
  kLyricist: 'Lyricist',
  kIsrc: 'ISRC',
  kLabel: 'Label',
  kCatalogNumber: 'Catalog #',
  kBarcode: 'Barcode',
  kCopyright: 'Copyright',
  kBpm: 'BPM',
  kKey: 'Key',
  kLanguage: 'Language',
  kComment: 'Comment',
  kCompilation: 'Compilation',
  kReleaseType: 'Release type',
  kEncoder: 'Encoder',
};

/// Read every text tag in [path]. Never throws; an unreadable or
/// unknown file yields an empty result.
TagFields readTagFields(String path) {
  if (path.isEmpty) return const TagFields({}, 'none');
  final lower = path.toLowerCase();
  try {
    List<int> head;
    try {
      final raf = File(path).openSync();
      try {
        head = raf.readSync(12);
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      ArchLog.w('tags', 'cannot open for tag read ($e) $path');
      return const TagFields({}, 'none');
    }
    if (head.length >= 8 &&
        head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70) {
      return TagFields(_mp4Fields(path), 'mp4');
    }
    if (head.length >= 4 &&
        head[0] == 0x66 &&
        head[1] == 0x4C &&
        head[2] == 0x61 &&
        head[3] == 0x43) {
      return TagFields(_vorbisFields(path), 'flac');
    }
    if (head.length >= 3 &&
        head[0] == 0x49 &&
        head[1] == 0x44 &&
        head[2] == 0x33) {
      return TagFields(_id3Fields(path), 'id3');
    }
    if (head.length >= 4 &&
        head[0] == 0x4F &&
        head[1] == 0x67 &&
        head[2] == 0x67 &&
        head[3] == 0x53) {
      return TagFields(_vorbisFields(path), 'vorbis');
    }
    if (lower.endsWith('.mp3')) return TagFields(_id3Fields(path), 'id3');
    if (lower.endsWith('.flac')) return TagFields(_vorbisFields(path), 'flac');
    if (lower.endsWith('.m4a') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.m4b')) {
      return TagFields(_mp4Fields(path), 'mp4');
    }
    if (lower.endsWith('.ogg') ||
        lower.endsWith('.oga') ||
        lower.endsWith('.opus')) {
      return TagFields(_vorbisFields(path), 'vorbis');
    }
    return const TagFields({}, 'unknown');
  } catch (e) {
    ArchLog.w('tags', 'tag read failed ($e) $path');
    return const TagFields({}, 'none');
  }
}

// ------------------------------------------------------------- Vorbis

Map<String, String> _vorbisFields(String path) {
  final out = <String, String>{};
  for (final entry in vorbisComments(path)) {
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final key = entry.substring(0, eq).trim().toUpperCase();
    final value = entry.substring(eq + 1).trim();
    if (value.isEmpty) continue;
    final canonical = _vorbisKey(key);
    // First writer wins: a second TITLE is a duplicate, not an update.
    if (canonical != null) out.putIfAbsent(canonical, () => value);
  }
  // Vorbis allows either "3/12" in one field or separate totals.
  _splitNumbered(out, kTrack, kTrackTotal);
  _splitNumbered(out, kDisc, kDiscTotal);
  return out;
}

/// "3/12" splits into number and total; a bare number stays put.
void _splitNumbered(
    Map<String, String> out, String key, String totalKey) {
  final v = out[key];
  if (v == null || !v.contains('/')) return;
  final parts = v.split('/');
  final n = parts.first.trim();
  final t = parts.length > 1 ? parts[1].trim() : '';
  if (n.isNotEmpty) out[key] = n;
  if (t.isNotEmpty && !out.containsKey(totalKey)) out[totalKey] = t;
}

String? _vorbisKey(String key) => switch (key) {
      'TITLE' => kTitle,
      'ARTIST' || 'PERFORMER' => kArtist,
      'ALBUMARTIST' || 'ALBUM ARTIST' || 'ENSEMBLE' => kAlbumArtist,
      'ALBUM' => kAlbum,
      'TRACKNUMBER' || 'TRACK' => kTrack,
      'TRACKTOTAL' || 'TOTALTRACKS' => kTrackTotal,
      'DISCNUMBER' || 'DISC' => kDisc,
      'DISCTOTAL' || 'TOTALDISCS' => kDiscTotal,
      'DATE' || 'YEAR' => kDate,
      'GENRE' => kGenre,
      'COMPOSER' => kComposer,
      'LYRICIST' || 'TEXT' => kLyricist,
      'ISRC' => kIsrc,
      'LABEL' || 'PUBLISHER' || 'ORGANIZATION' => kLabel,
      'CATALOGNUMBER' || 'CATALOG' => kCatalogNumber,
      'BARCODE' => kBarcode,
      'COPYRIGHT' => kCopyright,
      'BPM' => kBpm,
      'KEY' || 'INITIALKEY' => kKey,
      'LANGUAGE' => kLanguage,
      'COMMENT' || 'DESCRIPTION' => kComment,
      'ENCODER' || 'ENCODEDBY' || 'ENCODERSETTINGS' => kEncoder,
      'COMPILATION' => kCompilation,
      'RELEASETYPE' || 'MUSICBRAINZ_ALBUMTYPE' => kReleaseType,
      _ => null,
    };

// ---------------------------------------------------------------- ID3

/// v2.3/v2.4 frame ids, plus the v2.2 three-char spellings.
const _id3Keys = <String, String>{
  'TIT2': kTitle, 'TT2': kTitle,
  'TPE1': kArtist, 'TP1': kArtist,
  'TPE2': kAlbumArtist, 'TP2': kAlbumArtist,
  'TALB': kAlbum, 'TAL': kAlbum,
  'TRCK': kTrack, 'TRK': kTrack,
  'TPOS': kDisc, 'TPA': kDisc,
  // v2.4 holds a full ISO date; v2.3 splits year (TYER) and DDMM
  // (TDAT), which are recombined after the walk. Both map to kDate.
  'TDRC': kDate,
  'TCON': kGenre, 'TCO': kGenre,
  'TCOM': kComposer, 'TCM': kComposer,
  'TEXT': kLyricist, 'TXT': kLyricist,
  'TSRC': kIsrc, 'TRC': kIsrc,
  'TPUB': kLabel, 'TPB': kLabel,
  'TCOP': kCopyright, 'TCR': kCopyright,
  'TBPM': kBpm, 'TBP': kBpm,
  'TKEY': kKey, 'TKE': kKey,
  'TLAN': kLanguage, 'TLA': kLanguage,
  'TENC': kEncoder, 'TEN': kEncoder, 'TSSE': kEncoder,
  'TCMP': kCompilation, 'TCP': kCompilation,
};

Map<String, String> _id3Fields(String path) {
  final out = <String, String>{};
  try {
    final raf = File(path).openSync();
    try {
      final head = raf.readSync(10);
      if (head.length < 10) return out;
      final ver = head[3];
      if (ver != 2 && ver != 3 && ver != 4) return out;
      final flags = head[5];
      final size = _syncSafe(head, 6);
      if (size <= 0 || size > 32 * 1024 * 1024) return out;
      var pos = 10;
      final end = 10 + size;
      if ((flags & 0x40) != 0) {
        raf.setPositionSync(pos);
        final ext = raf.readSync(4);
        if (ext.length < 4) return out;
        pos += ver == 4 ? _syncSafe(ext, 0) : _be32(ext, 0) + 4;
      }
      final hdr = ver == 2 ? 6 : 10;
      var guard = 0;
      String? id3Year;
      String? id3DayMonth;
      while (pos + hdr <= end && guard < 512) {
        guard++;
        raf.setPositionSync(pos);
        final fh = raf.readSync(hdr);
        if (fh.length < hdr) break;
        final idLen = ver == 2 ? 3 : 4;
        final id = String.fromCharCodes(fh.sublist(0, idLen));
        if (id.codeUnitAt(0) == 0) break; // padding
        final len = ver == 2
            ? ((fh[3] << 16) | (fh[4] << 8) | fh[5])
            : (ver == 4 ? _syncSafe(fh, 4) : _be32(fh, 4));
        if (len < 0 || len > 16 * 1024 * 1024) break;
        // ID3v2.3 date halves, captured for recombination below.
        final isYear = id == 'TYER' || id == 'TYE';
        final isDayMonth = id == 'TDAT' || id == 'TDA';
        if (_id3Keys.containsKey(id) ||
            isYear ||
            isDayMonth ||
            id == 'TXXX' ||
            id == 'COMM' ||
            id == 'TXX' ||
            id == 'COM') {
          final data = Uint8List.fromList(raf.readSync(len));
          if (data.length < len) break;
          if (isYear || isDayMonth) {
            final text = _decodeText(data);
            if (text != null && text.isNotEmpty) {
              if (isYear) {
                id3Year ??= text;
              } else {
                id3DayMonth ??= text;
              }
            }
          } else if (id == 'TXXX' || id == 'TXX') {
            final parts = _txxx(data);
            if (parts != null) {
              final canonical = _txxxKey(parts.$1);
              if (canonical != null) {
                out.putIfAbsent(canonical, () => parts.$2);
              }
            }
          } else if (id == 'COMM' || id == 'COM') {
            final text = _comment(data);
            if (text != null) out.putIfAbsent(kComment, () => text);
          } else {
            final text = _decodeText(data);
            if (text != null && text.isNotEmpty) {
              final canonical = _id3Keys[id]!;
              if (canonical == kTrack || canonical == kDisc) {
                _addNumbered(out, canonical, text);
              } else {
                // A later duplicate must not overwrite the first.
                out.putIfAbsent(canonical, () => text);
              }
            }
          }
        }
        pos += hdr + len;
      }
      // ID3v2.3: TYER + TDAT(DDMM) recombine into one ISO date, so we
      // keep 2.3's wide compatibility without losing the day and month.
      if (id3Year != null && !out.containsKey(kDate)) {
        var date = id3Year;
        final dm = id3DayMonth;
        if (dm != null && dm.length >= 4) {
          date = '$id3Year-${dm.substring(2, 4)}-${dm.substring(0, 2)}';
        }
        out[kDate] = date;
      }
    } finally {
      raf.closeSync();
    }
  } catch (e) {
    ArchLog.w('tags', 'id3 read failed ($e) $path');
  }
  return out;
}

/// "3/12" splits into number and total for track and disc.
void _addNumbered(Map<String, String> out, String key, String raw) {
  final parts = raw.split('/');
  final n = parts.first.trim();
  if (n.isNotEmpty && !out.containsKey(key)) out[key] = n;
  if (parts.length > 1) {
    final total = parts[1].trim();
    final totalKey = key == kTrack ? kTrackTotal : kDiscTotal;
    if (total.isNotEmpty && !out.containsKey(totalKey)) out[totalKey] = total;
  }
}

String? _txxxKey(String desc) => switch (desc.trim().toUpperCase()) {
      'CATALOGNUMBER' || 'CATALOG NUMBER' || 'CATALOG' => kCatalogNumber,
      'BARCODE' || 'UPC' || 'EAN' => kBarcode,
      'ISRC' => kIsrc,
      'LABEL' || 'PUBLISHER' => kLabel,
      'BPM' => kBpm,
      'KEY' || 'INITIALKEY' => kKey,
      'LYRICIST' => kLyricist,
      'COMPOSER' => kComposer,
      // ffmpeg's ID3v2 writer puts these in TXXX with lowercase
      // descriptors and writes no COMM frame at all.
      'COMMENT' || 'DESCRIPTION' => kComment,
      'LANGUAGE' => kLanguage,
      'ALBUMARTIST' => kAlbumArtist,
      'RELEASETYPE' => kReleaseType,
      _ => null,
    };

/// TXXX: encoding, description (nul), value.
(String, String)? _txxx(Uint8List data) {
  if (data.length < 2) return null;
  final enc = data[0];
  var i = 1;
  final sep = _terminator(data, i, enc);
  if (sep < 0) return null;
  final desc = _decode(data.sublist(i, sep), enc);
  i = sep + (enc == 1 || enc == 2 ? 2 : 1);
  if (i >= data.length) return null;
  final value = _decode(data.sublist(i), enc);
  if (desc.isEmpty || value.isEmpty) return null;
  return (desc, value);
}

/// COMM: encoding, language(3), description (nul), text.
String? _comment(Uint8List data) {
  if (data.length < 5) return null;
  final enc = data[0];
  final sep = _terminator(data, 4, enc);
  final from = sep < 0 ? 4 : sep + (enc == 1 || enc == 2 ? 2 : 1);
  if (from >= data.length) return null;
  final text = _decode(data.sublist(from), enc);
  return text.isEmpty ? null : text;
}

int _terminator(Uint8List b, int from, int enc) {
  if (enc == 1 || enc == 2) {
    for (var i = from; i + 1 < b.length; i++) {
      if (b[i] == 0 && b[i + 1] == 0) return i;
    }
    return -1;
  }
  for (var i = from; i < b.length; i++) {
    if (b[i] == 0) return i;
  }
  return -1;
}

/// Text frame body: encoding byte then the string.
String? _decodeText(Uint8List data) {
  if (data.length < 2) return null;
  return _decode(data.sublist(1), data[0]);
}

String _decode(Uint8List body, int enc) {
  try {
    String s;
    if (enc == 1 || enc == 2) {
      var b = body;
      var little = false;
      // enc 1 is UTF-16 with a BOM; enc 2 is UTF-16BE without one.
      if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        little = true;
        b = b.sublist(2);
      } else if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        b = b.sublist(2);
      }
      if (b.length < 2) return '';
      final units = <int>[];
      for (var i = 0; i + 1 < b.length; i += 2) {
        units.add(little ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]));
      }
      s = String.fromCharCodes(units);
    } else if (enc == 3) {
      s = utf8.decode(body, allowMalformed: true);
    } else {
      s = latin1.decode(body, allowInvalid: true);
    }
    // ID3 counts a NUL terminator inside the frame size, and NUL is
    // not whitespace, so trim() alone left "\x00" on every value.
    return s.replaceAll('\u0000', '').trim();
  } catch (_) {
    return '';
  }
}

// ---------------------------------------------------------------- MP4

/// ilst atom -> canonical key. `©` is byte 0xA9.
const _mp4Keys = <String, String>{
  '\u00A9nam': kTitle,
  '\u00A9ART': kArtist,
  'aART': kAlbumArtist,
  '\u00A9alb': kAlbum,
  '\u00A9day': kDate,
  '\u00A9gen': kGenre,
  '\u00A9wrt': kComposer,
  '\u00A9cmt': kComment,
  'cprt': kCopyright,
  '\u00A9too': kEncoder,
  '\u00A9grp': kCompilation,
};

/// Freeform atoms (`----:com.apple.iTunes:ISRC`) other tools leave.
const _mp4FreeKeys = <String, String>{
  'ISRC': kIsrc,
  'LABEL': kLabel,
  'CATALOGNUMBER': kCatalogNumber,
  'BARCODE': kBarcode,
  'BPM': kBpm,
  'KEY': kKey,
  'LYRICIST': kLyricist,
  'LANGUAGE': kLanguage,
};

Map<String, String> _mp4Fields(String path) {
  final out = <String, String>{};
  try {
    final raf = File(path).openSync();
    try {
      final fileLen = raf.lengthSync();
      if (fileLen <= 0) return out;
      final want = ['moov', 'udta', 'meta', 'ilst'];
      final ends = <int>[fileLen];
      var pos = 0;
      var depth = 0;
      var guard = 0;
      List<int>? ilst;
      while (pos + 8 <= ends.last && guard < 8192) {
        guard++;
        raf.setPositionSync(pos);
        final head = raf.readSync(8);
        if (head.length < 8) return out;
        var size = _be32(head, 0);
        final type = String.fromCharCodes(head.sublist(4, 8));
        var headerLen = 8;
        if (size == 1) {
          final ext = raf.readSync(8);
          if (ext.length < 8) return out;
          size = _be64(ext);
          headerLen = 16;
        }
        if (size <= 0) return out;
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
      if (ilst == null) return out;
      var cpos = ilst[0];
      final cend = ilst[1];
      guard = 0;
      while (cpos + 8 <= cend && guard < 256) {
        guard++;
        raf.setPositionSync(cpos);
        final head = raf.readSync(8);
        if (head.length < 8) break;
        final size = _be32(head, 0);
        final type = String.fromCharCodes(head.sublist(4, 8));
        if (size < 8) break;
        if (type == 'trkn' || type == 'disk' || type == 'tmpo' ||
            _mp4Keys.containsKey(type) ||
            type == '----' ||
            type == 'gnre') {
          final data = Uint8List.fromList(raf.readSync(size - 8));
          _mp4Entry(out, type, data);
        }
        cpos += size;
      }
    } finally {
      raf.closeSync();
    }
  } catch (e) {
    ArchLog.w('tags', 'mp4 read failed ($e) $path');
  }
  return out;
}

/// An ilst entry holds one or more `data` atoms; the first wins.
void _mp4Entry(Map<String, String> out, String type, Uint8List body) {
  final payload = _firstDataPayload(body);
  if (payload == null || payload.isEmpty) return;
  switch (type) {
    case 'trkn':
      _addNumbered(out, kTrack,
          '${_be16(payload, 2)}/${_be16(payload, 4)}');
    case 'disk':
      _addNumbered(out, kDisc, '${_be16(payload, 2)}/${_be16(payload, 4)}');
    case 'tmpo':
      final v = _be16(payload, 0);
      if (v > 0) out.putIfAbsent(kBpm, () => '$v');
    default:
      if (type == '----') {
        // Freeform: mean, name, then the data atom payload.
        final name = _freeformName(body);
        if (name == null) return;
        final canonical = _mp4FreeKeys[name.toUpperCase()];
        if (canonical == null) return;
        final text = utf8.decode(payload, allowMalformed: true).trim();
        if (text.isNotEmpty) out.putIfAbsent(canonical, () => text);
        return;
      }
      final canonical = _mp4Keys[type];
      if (canonical == null) return;
      final text = utf8.decode(payload, allowMalformed: true).trim();
      if (text.isNotEmpty) out.putIfAbsent(canonical, () => text);
  }
}

/// Walk the child atoms of an ilst entry and return the first `data`
/// atom's payload (skipping its 4-byte type/flags word).
Uint8List? _firstDataPayload(Uint8List body) {
  var pos = 0;
  while (pos + 8 <= body.length) {
    final size = _be32(body, pos);
    final type = String.fromCharCodes(body.sublist(pos + 4, pos + 8));
    if (size < 8 || pos + size > body.length) return null;
    if (type == 'data') {
      if (size <= 16) return null;
      return Uint8List.sublistView(body, pos + 16, pos + size);
    }
    pos += size;
  }
  return null;
}

/// `----` entry name: mean then name atoms, both `data`-free.
String? _freeformName(Uint8List body) {
  var pos = 0;
  String? name;
  while (pos + 8 <= body.length) {
    final size = _be32(body, pos);
    final type = String.fromCharCodes(body.sublist(pos + 4, pos + 8));
    if (size < 8 || pos + size > body.length) break;
    if (type == 'name' && size > 12) {
      name = utf8.decode(
        Uint8List.sublistView(body, pos + 12, pos + size),
        allowMalformed: true,
      ).trim();
    }
    pos += size;
  }
  return name;
}

// ------------------------------------------------------------ helpers

int _be16(Uint8List b, int i) =>
    i + 2 > b.length ? 0 : ((b[i] << 8) | b[i + 1]);

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
