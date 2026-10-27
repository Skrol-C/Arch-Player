/// Build-time changelog generator: `git log` -> assets/changelog.json.
///
/// Run: `dart tool/gen_changelog.dart` from the repo root, before
/// release builds. The file is bundled with the app so the
/// Changelog and Updater screens work fully offline.
///
/// Output schema (one object per line in the git log pass):
/// generatedAt as iso8601 utc, plus a commits array of hash,
/// message, author and date objects.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final root = Directory.current;
  final log = await Process.run('git', [
    'log',
    '--format={"hash":"%H","message":"%s","author":"%an","date":"%ad"}',
    '--date=short',
    '-n',
    '200',
  ], workingDirectory: root.path);
  if (log.exitCode != 0) {
    stderr.writeln('gen_changelog: git log failed: ${log.stderr}');
    exit(1);
  }
  final commits = <Map<String, String>>[];
  for (final line in (log.stdout as String).split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    try {
      final m = jsonDecode(t) as Map<String, dynamic>;
      commits.add({
        'hash': '${m['hash'] ?? ''}',
        'message': _clean('${m['message'] ?? ''}'),
        'author': '${m['author'] ?? ''}',
        'date': '${m['date'] ?? ''}',
      });
    } catch (_) {
      // One malformed subject line never kills the bundle.
    }
  }
  final out = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'commits': commits,
  };
  final file = File('${root.path}/assets/changelog.json');
  await file.parent.create(recursive: true);
  // Pretty print keeps diffs reviewable.
  const encoder = JsonEncoder.withIndent('  ');
  await file.writeAsString('${encoder.convert(out)}\n');
  stdout.writeln(
    'gen_changelog: wrote ${commits.length} commits -> ${file.path}',
  );
}

/// Escape hatch doubles (`\"`) inside subjects break naive decodes;
/// git already JSON-escapes, so this only trims control junk.
String _clean(String s) => s.trim();
