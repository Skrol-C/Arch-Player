import 'dart:convert';

import 'package:flutter/services.dart';

/// One commit in the bundled changelog: short hash, subject line,
/// author, and date. Generated at build time by `tool/gen_changelog.dart`
/// from `git log`, never hand-edited, never fetched at runtime.
class ChangelogEntry {
  final String hash;
  final String message;
  final String author;
  final String date;

  const ChangelogEntry({
    required this.hash,
    required this.message,
    required this.author,
    required this.date,
  });

  factory ChangelogEntry.fromJson(Map<String, dynamic> j) => ChangelogEntry(
    hash: '${j['hash'] ?? ''}',
    message: '${j['message'] ?? ''}',
    author: '${j['author'] ?? ''}',
    date: '${j['date'] ?? ''}',
  );

  /// First 7 hex chars, like `git log --oneline`.
  String get short =>
      hash.length >= 7 ? hash.substring(0, 7) : hash;

  /// GitHub profile picture for the author name. Renderers must cache
  /// this and fall back to initials when offline or unknown.
  String get avatarUrl => 'https://github.com/$author.png';
}

/// Parses the bundled `assets/changelog.json`. Pure function over the
/// decoded JSON so it is unit-testable without asset binding.
List<ChangelogEntry> parseChangelog(Object? decoded) {
  if (decoded is! Map) return const [];
  final raw = decoded['commits'];
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map<String, dynamic>) ChangelogEntry.fromJson(e)
      else if (e is Map)
        ChangelogEntry.fromJson(
          e.map((k, v) => MapEntry('$k', v)),
        ),
  ];
}

/// Bundled changelog version stamp (the file's `generatedAt` field,
/// empty when the bundle is missing).
String changelogStamp(Object? decoded) {
  if (decoded is! Map) return '';
  return '${decoded['generatedAt'] ?? ''}';
}

Future<List<ChangelogEntry>> loadChangelog() async {
  try {
    final raw = await rootBundle.loadString('assets/changelog.json');
    return parseChangelog(jsonDecode(raw));
  } catch (_) {
    return const [];
  }
}
