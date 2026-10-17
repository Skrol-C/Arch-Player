import 'dart:io';

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
      // Music videos arrive as .m4a with an h264 stream; take the
      // audio only. The m4a (ipod) muxer cannot hold h264 at all.
      opts.addAll(['-map', '0:a']);
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
            '-map', '1:0',
            '-c:a', 'copy', '-c:v', 'mjpeg', '-q:v', _coverQ, '-vf', _coverVf,
            '-disposition:v', 'attached_pic',
          ]);
        } else {
          // ogg/opus picture blocks need base64 COMMENT mapping;
          // skip art for those (tags still land).
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
    final argv = <String>[
      '-y', '-v', 'error',
      ...inputs,
      ...opts,
      if (coverPath == null) ...['-c', 'copy'],
      out,
    ];
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
    final log = (await session.getOutput()) ?? '';
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

Future<String?> _fetchCover(String url) async {
  try {
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
