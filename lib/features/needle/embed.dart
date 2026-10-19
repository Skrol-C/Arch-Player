import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import 'enrich.dart';

/// Cover art is re-encoded, never copied. Cover Art Archive hands
/// back originals that run to 5MB (a 3000px scan) — more than the
/// audio itself. Capped at 1400px, mjpeg q3: measured 37.3dB/0.945
/// SSIM against the original shown at 1200px (the largest any
/// screen draws), ~510KB. Copies are a false economy: at equal
/// bytes a lower cap beats a higher one, because pixels past the
/// display size are resampled away.
const _coverVf = "scale='min(1400,iw)':-2";
const _coverQ = '3';

/// Tag embed at pull time: writes PullMeta into the staged file
/// with ffmpeg, one command, audio bytes untouched (`-c copy`).
/// Per-container maps: ID3 (mp3), Vorbis comments + picture
/// block (flac/ogg/opus), MP4 atoms (m4a). Only LRCLib-sourced
/// lyrics embed (source gate); PaxSenIX/Musixmatch lines stay
/// display + cache only, per their terms. Cover art embeds
/// when fetched; missing pieces are omitted, never blank tags.
/// [containerExt] is the sniffed real container: providers hand
/// back an MP4 music video named `.m4a`, and the extension lies.
/// Returns the tagged path (possibly rewritten), or the input
/// path when there is nothing worth writing or tagging fails.
Future<String> embedPullMeta(String stagedPath, PullMeta meta,
    {String? containerExt}) async {
  try {
    final ext =
        (containerExt ?? stagedPath.toLowerCase().split('.').last).toLowerCase();
    // ffmpeg is positional: every input first, then output options.
    // An output option placed before an input rebinds to that input
    // and errors ("metadata cannot be applied to input url") — the
    // cover's -i must precede the -metadata block. Args are a list
    // (executeWithArguments): no shell split, so spaces survive.
    final inputs = <String>['-i', stagedPath];
    final opts = <String>[];
    var writes = 0;

    void tag(String k, String v) {
      final val = v.trim();
      if (val.isEmpty) return;
      opts.addAll(['-metadata', '$k=$val']);
      writes++;
    }

    if (ext == 'mp3') {
      tag('title', meta.title);
      tag('artist', meta.artist);
      tag('album', meta.album);
      if (meta.genres.isNotEmpty) tag('genre', meta.genres.first);
      tag('publisher', meta.label);
      tag('isrc', meta.isrc);
      tag('composer', meta.composer);
      tag('track', _num(meta.trackNumber, meta.trackTotal));
      tag('disc', _num(meta.discNumber, meta.discTotal));
      tag('date', meta.date);
      tag('album_artist', meta.albumArtist);
      tag('copyright', meta.copyright);
      tag('bpm', meta.bpm);
      tag('catalognumber', meta.catalogNumber);
      tag('barcode', meta.barcode);
      if (_embeddable(meta.lyrics)) {
        final lrc = meta.lyrics.syncedLrc;
        if (lrc != null && lrc.isNotEmpty) {
          tag('lyrics', lrc);
          writes++;
        } else if ((meta.lyrics.plain ?? '').isNotEmpty) {
          tag('lyrics', meta.lyrics.plain!);
          writes++;
        }
      }
    } else if (ext == 'flac' || ext == 'ogg' || ext == 'oga' || ext == 'opus') {
      tag('TITLE', meta.title);
      tag('ARTIST', meta.artist);
      tag('ALBUM', meta.album);
      if (meta.genres.isNotEmpty) tag('GENRE', meta.genres.first);
      tag('LABEL', meta.label);
      tag('ISRC', meta.isrc);
      tag('COMPOSER', meta.composer);
      // Vorbis spells the numbers out and keeps the totals separate.
      tag('TRACKNUMBER', meta.trackNumber);
      tag('TRACKTOTAL', meta.trackTotal);
      tag('DISCNUMBER', meta.discNumber);
      tag('DISCTOTAL', meta.discTotal);
      tag('DATE', meta.date);
      tag('ALBUMARTIST', meta.albumArtist);
      tag('COPYRIGHT', meta.copyright);
      tag('BPM', meta.bpm);
      tag('CATALOGNUMBER', meta.catalogNumber);
      tag('BARCODE', meta.barcode);
      tag('RELEASETYPE', meta.releaseType);
      if (_embeddable(meta.lyrics)) {
        final lrc = meta.lyrics.syncedLrc;
        if (lrc != null && lrc.isNotEmpty) {
          tag('LYRICS', lrc);
          writes++;
        } else if ((meta.lyrics.plain ?? '').isNotEmpty) {
          tag('LYRICS', meta.lyrics.plain!);
          writes++;
        }
      }
    } else if (ext == 'm4a' || ext == 'mp4' || ext == 'm4b') {
      // No unconditional `-map 0:a` here. An mp4 cover is an
      // attached_pic VIDEO stream, so mapping audio alone silently
      // strips the artwork from a lyrics-only retag (verified: a
      // 300x300 mjpeg cover survives `-c copy` but dies the moment
      // `-map 0:a` is present). Music videos are handled by the
      // audio-only retry after a failed run instead.
      tag('title', meta.title);
      tag('artist', meta.artist);
      tag('album', meta.album);
      if (meta.genres.isNotEmpty) tag('genre', meta.genres.first);
      tag('label', meta.label);
      tag('isrc', meta.isrc);
      tag('composer', meta.composer);
      // movenc maps these onto standard atoms: trkn, disk, (c)day,
      // aART, cprt. Five fields have NO standard atom and ffmpeg will
      // not write them here under any spelling (verified: isrc, label,
      // catalognumber, barcode, and bpm/tmpo) - they stay mp3/flac-only
      // in-file, and display-only for m4a.
      tag('track', _num(meta.trackNumber, meta.trackTotal));
      tag('disc', _num(meta.discNumber, meta.discTotal));
      tag('date', meta.date);
      tag('album_artist', meta.albumArtist);
      tag('copyright', meta.copyright);
      if (_embeddable(meta.lyrics)) {
        final lrc = meta.lyrics.syncedLrc;
        if (lrc != null && lrc.isNotEmpty) {
          tag('lyrics', lrc);
          writes++;
        } else if ((meta.lyrics.plain ?? '').isNotEmpty) {
          tag('lyrics', meta.lyrics.plain!);
          writes++;
        }
      }
    } else {
      ArchLog.i('embed', 'no tag map for .$ext, skipping');
      return stagedPath;
    }

    String? coverPath;
    if (meta.coverUrl.isNotEmpty) {
      coverPath = await _fetchCover(meta.coverUrl);
      if (coverPath != null) {
        inputs.addAll(['-i', coverPath]);
        var mapped = true;
        if (ext == 'mp3') {
          opts.addAll([
            '-map', '0:a', '-map', '1:0',
            '-c:a', 'copy', '-c:v', 'mjpeg', '-q:v', _coverQ, '-vf', _coverVf,
            '-metadata:s:v', 'title=cover',
            '-metadata:s:v', 'comment=Cover (front)',
            '-disposition:v', 'attached_pic',
          ]);
        } else if (ext == 'flac') {
          opts.addAll([
            '-map', '0:a', '-map', '1:0',
            '-c:a', 'copy', '-c:v', 'mjpeg', '-q:v', _coverQ, '-vf', _coverVf,
            '-disposition:v', 'attached_pic',
          ]);
        } else if (ext == 'm4a' || ext == 'mp4' || ext == 'm4b') {
          opts.addAll([
            '-map', '0:a', '-map', '1:0',
            '-c:a', 'copy', '-c:v', 'mjpeg', '-q:v', _coverQ, '-vf', _coverVf,
            '-disposition:v', 'attached_pic',
          ]);
        } else if (ext == 'ogg' || ext == 'oga' || ext == 'opus') {
          // Vorbis comments carry art as a base64 PICTURE block, not
          // a stream: the ogg muxer rejects attached_pic outright.
          // Re-encode to the same cap, build the block in Dart, pass
          // it as a comment. `-map 0:a` drops any pre-existing video
          // streams (a re-applied cover must not leave stale art
          // behind for stream-reading players); audio stays `-c copy`
          // via the shared coverPath = null path below.
          final block = await _coverPictureBlock(coverPath);
          if (block != null) {
            opts.addAll([
              '-map', '0:a', '-metadata', 'METADATA_BLOCK_PICTURE=$block',
            ]);
            writes++;
          }
          // The image is comment data, never a stream: always drop
          // the `-i` added above, whether the block built or not.
          mapped = false;
        } else {
          mapped = false;
        }
        if (mapped) {
          writes++;
        } else {
          inputs.removeRange(inputs.length - 2, inputs.length);
          coverPath = null;
        }
      }
    }
    if (writes == 0) return stagedPath;

    final sep = stagedPath.lastIndexOf('/') > stagedPath.lastIndexOf('\\')
        ? stagedPath.lastIndexOf('/')
        : stagedPath.lastIndexOf('\\');
    final dot = stagedPath.lastIndexOf('.');
    // Only strip a real extension: a '.' inside a directory name
    // must not become the split point.
    final base =
        dot > sep + 1 ? stagedPath.substring(0, dot) : stagedPath;
    final out = '${base}_tagged.$ext';
    List<String> buildArgv({String? forceFormat, bool audioOnly = false}) {
      final a = <String>[
        '-y', '-v', 'error',
        ...inputs,
        // Audio-only is the music-video fallback: providers hand back
        // an MP4 with an h264 stream named `.m4a`, and the ipod muxer
        // cannot hold h264 at all. Never the default — an attached_pic
        // cover is a video stream too, and mapping audio alone drops
        // the artwork.
        if (audioOnly && coverPath == null) ...['-map', '0:a'],
        ...opts,
        if (coverPath == null) ...['-c', 'copy'],
      ];
      if (forceFormat != null) a.addAll(['-f', forceFormat]);
      a.add(out);
      return a;
    }

    Future<(ReturnCode?, String)> runTag(List<String> argv) async {
      final session = await FFmpegKit.executeWithArguments(argv).timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          // Abandoning the future does NOT kill the process, and
          // FFmpegKit serializes sessions: a stalled call blocks
          // every later one (the "stuck on embedding" hang).
          FFmpegKit.cancel();
          throw StateError('embed timed out');
        },
      );
      final code = await session.getReturnCode();
      final log = (await session.getOutput()) ?? '';
      return (code, log);
    }

    var (code, log) = await runTag(buildArgv());
    if (!ReturnCode.isSuccess(code) &&
        (ext == 'm4a' || ext == 'mp4' || ext == 'm4b') &&
        !log.contains('Could not find tag for codec')) {
      // A real video stream (music video named .m4a) fails the ipod
      // muxer. Retry once with audio only — the behaviour the old
      // unconditional `-map 0:a` gave, now applied only when needed.
      // A codec-tag failure is a different disease (see below), so it
      // skips this pass and goes straight to the mp4 muxer.
      ArchLog.i('embed',
          'tag command failed for .$ext, retrying audio-only: ${_clip(log)}');
      (code, log) = await runTag(buildArgv(audioOnly: true));
    }
    if (!ReturnCode.isSuccess(code) &&
        (ext == 'm4a' || ext == 'mp4' || ext == 'm4b') &&
        log.contains('Could not find tag for codec')) {
      // Codec/container mismatch the extension hides: observed
      // FLAC-in-.m4a from providers (magic says ftyp, stream says
      // flac). The ipod muxer refuses the stream outright; the mp4
      // muxer takes the same bytes with -c copy (verified: ©-atoms
      // + covr land, audio untouched). Retry once — anything else
      // fails the same way below.
      ArchLog.i('embed',
          'ipod muxer refused codec for .$ext, retrying with mp4 muxer');
      (code, log) = await runTag(buildArgv(forceFormat: 'mp4'));
    }
    final f = File(out);
    if (ReturnCode.isSuccess(code) &&
        await f.exists() &&
        await f.length() > 0) {
      try {
        await File(stagedPath).delete();
      } catch (_) {}
      ArchLog.i('embed', 'tagged $ext ($writes writes)');
      return out;
    }
    try {
      await f.delete();
    } catch (_) {}
    // Diagnosability: a bare "failed" burns device round-trips.
    ArchLog.w('embed',
        'tag command failed for .$ext (code ${code?.getValue()}) ${_clip(log)}');
    return stagedPath;
  } catch (e) {
    ArchLog.w('embed', 'embed failed: $e');
    return stagedPath;
  }
}

/// "3" of "12" -> "3/12"; a bare number stays bare.
String _num(String n, String total) =>
    n.isEmpty ? '' : (total.isEmpty ? n : '$n/$total');

bool _embeddable(LyricDoc doc) =>
    doc.source == LyricSource.lrclib &&
    (doc.hasSynced || doc.hasPlain);

String _clip(String s) {
  final one = s.replaceAll('\n', ' | ').trim();
  return one.length > 500 ? '${one.substring(0, 500)}…' : one;
}

/// Cover bytes as a base64 FLAC PICTURE block for Vorbis comments
/// (ogg/oga/opus). The fetched file is re-encoded to the same cap
/// first, so the block stays ~500KB, not the 5MB CAA originals can
/// run to. Returns null on any failure — caller falls back to
/// tags-only, never wedges the pull.
Future<String?> _coverPictureBlock(String coverPath) async {
  File? small;
  try {
    final dir = await getTemporaryDirectory();
    small = File(
        '${dir.path}/embed_pic_${DateTime.now().millisecondsSinceEpoch}.jpg');
    final session = await FFmpegKit.executeWithArguments([
      '-y', '-v', 'error', '-i', coverPath,
      '-vf', _coverVf, '-c:v', 'mjpeg', '-q:v', _coverQ, small.path,
    ]).timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        FFmpegKit.cancel();
        throw StateError('cover re-encode timed out');
      },
    );
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code) ||
        !await small.exists() ||
        await small.length() == 0) {
      return null;
    }
    final bytes = await small.readAsBytes();
    if (bytes.length < 4) return null;
    // PICTURE block: type 3 (front cover), mime, empty desc, zero
    // dims (legal: unknown), data. Re-encoded above so always jpeg.
    final mime = (bytes[0] == 0xFF && bytes[1] == 0xD8)
        ? 'image/jpeg'
        : 'image/png';
    final b = BytesBuilder();
    void u32(int v) => b.add(
        [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
    u32(3);
    u32(mime.length);
    b.add(mime.codeUnits);
    u32(0);
    u32(0);
    u32(0);
    u32(0);
    u32(0);
    u32(bytes.length);
    b.add(bytes);
    return base64Encode(b.toBytes());
  } catch (_) {
    return null;
  } finally {
    try {
      if (small != null && await small.exists()) await small.delete();
    } catch (_) {}
  }
}

Future<String?> _fetchCover(String url) async {  try {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
    if (res.bodyBytes.length > 8 * 1024 * 1024) return null;
    final dir = await getApplicationCacheDirectory();
    final file = File(
        '${dir.path}/embed_cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(res.bodyBytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}
