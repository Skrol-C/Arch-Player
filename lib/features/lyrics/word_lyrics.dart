import 'dart:convert';

import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:yaml/yaml.dart';

/// Word-level lyric timings: LRCLib -> stage.
///
/// LRCLib answers carry a `lyricsfile` field (YAML: lines with
/// `start_ms`/`end_ms`, plus a `words` list per line when
/// `hasWordSync` is true). This file converts that into the compact
/// JSON the app stores on [LyricDoc.wordTimings], and back into a
/// [LyricDocument] the stage's sweep renderer already knows how to
/// paint (`line.words != null` -> `_SungLine`; null -> `_PinkLine`).
///
/// Word data is display + cache ONLY: no audio container holds word
/// timings, so it never embeds — same rule as PaxSenIX-sourced lines.

/// Parse an LRCLib `lyricsfile` (YAML text) into compact word-timings
/// JSON: `{"lines":[{"s":ms,"e":ms,"w":[[s,e,"text"],...]},...]}`.
/// Returns null when there are no usable word timings. Never throws.
String? wordTimingsFromLyricsFile(String? lyricsFile) {
  if (lyricsFile == null || lyricsFile.trim().isEmpty) return null;
  try {
    final doc = loadYaml(lyricsFile);
    if (doc is! YamlMap) return null;
    final lines = doc['lines'];
    if (lines is! YamlList) return null;
    final out = <Map<String, Object>>[];
    for (final l in lines) {
      if (l is! YamlMap) continue;
      final words = l['words'];
      if (words is! YamlList || words.isEmpty) continue;
      final w = <List<Object>>[];
      for (final word in words) {
        if (word is! YamlMap) continue;
        final text = '${word['text'] ?? ''}';
        final s = _ms(word['start_ms']);
        final e = _ms(word['end_ms']);
        if (text.isEmpty || s == null) continue;
        w.add([s, e ?? s, text]);
      }
      if (w.isEmpty) continue;
      final ls = _ms(l['start_ms']) ?? (w.first[0] as int);
      final le = _ms(l['end_ms']) ?? (w.last[0] as int);
      out.add({'s': ls, 'e': le, 'w': w});
    }
    if (out.isEmpty) return null;
    return jsonEncode({'lines': out});
  } catch (_) {
    return null;
  }
}

/// Build a word-timed [LyricDocument] from stored word-timings JSON.
/// Null when there is nothing usable — callers fall back to parsing
/// the line-level LRC. Never throws.
LyricDocument? documentFromWordTimings(String? wordTimings) {
  if (wordTimings == null || wordTimings.isEmpty) return null;
  try {
    final m = jsonDecode(wordTimings) as Map;
    final lines = (m['lines'] as List?) ?? const [];
    final out = <LyricLine>[];
    for (final l in lines) {
      if (l is! Map) continue;
      final words = <LyricWord>[];
      for (final wd in ((l['w'] as List?) ?? const [])) {
        if (wd is! List || wd.length < 3) continue;
        final s = (wd[0] as num?)?.toInt();
        final e = (wd[1] as num?)?.toInt();
        final text = '${wd[2]}';
        if (s == null || text.isEmpty) continue;
        words.add(LyricWord(
          text: text,
          start: Duration(milliseconds: s),
          end: e == null ? null : Duration(milliseconds: e),
        ));
      }
      if (words.isEmpty) continue;
      final ls =
          (l['s'] as num?)?.toInt() ?? words.first.start.inMilliseconds;
      final le = (l['e'] as num?)?.toInt();
      out.add(LyricLine(
        start: Duration(milliseconds: ls),
        end: le == null ? null : Duration(milliseconds: le),
        // Word texts carry their own trailing spaces (lyricsfile
        // convention), so plain join reconstructs the line.
        text: words.map((w) => w.text).join(),
        words: words,
      ));
    }
    if (out.isEmpty) return null;
    return LyricDocument(lines: out);
  } catch (_) {
    return null;
  }
}

int? _ms(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}
