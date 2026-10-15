import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../core/log.dart';
import 'needle_dirs.dart';

/// Registry client: fetch + ETag cache + hash verify. Mirrors the
/// community registry shape (id, display_name, version, description,
/// download_url, sha256, ...). Trust = HTTPS + content hash, nothing
/// else claimed.
class RegistryEntry {
  final String id;
  final String displayName;
  final String version;
  final String description;
  final String downloadUrl;
  final String sha256;

  const RegistryEntry({
    required this.id,
    required this.displayName,
    required this.version,
    required this.description,
    required this.downloadUrl,
    required this.sha256,
  });

  static RegistryEntry? fromJson(Map m) {
    try {
      final id = (m['id'] as String?) ?? '';
      final url = (m['download_url'] as String?) ?? '';
      if (id.isEmpty || !url.startsWith('https://')) return null;
      return RegistryEntry(
        id: id,
        displayName: (m['display_name'] as String?) ?? id,
        version: (m['version'] as String?) ?? '?',
        description: (m['description'] as String?) ?? '',
        downloadUrl: url,
        sha256: (m['sha256'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Fetch a registry index. ETag-cached on disk (30-min TTL honoured
/// via the server's own validators); corrupt cache self-deletes.
Future<List<RegistryEntry>> fetchRegistry(String url) async {
  if (!url.startsWith('https://')) return const [];
  final dir = await _dir();
  final key = _keyOf(url);
  final bodyFile = File('${dir.path}/$key.json');
  final etagFile = File('${dir.path}/$key.etag');
  String? etag;
  try {
    if (await etagFile.exists()) etag = await etagFile.readAsString();
  } catch (_) {}
  http.Response res;
  try {
    res = await http.get(
      Uri.parse(url),
      headers: {if (etag != null && etag.isNotEmpty) 'If-None-Match': etag},
    ).timeout(const Duration(seconds: 20));
  } catch (e) {
    ArchLog.w('needle', 'registry fetch failed: $e');
    return _readCached(bodyFile);
  }
  if (res.statusCode == 304) return _readCached(bodyFile);
  if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
    return _readCached(bodyFile);
  }
  try {
    await bodyFile.writeAsString(res.body, flush: true);
    final tag = res.headers['etag'];
    if (tag != null) await etagFile.writeAsString(tag, flush: true);
  } catch (_) {}
  return _parse(res.body);
}

/// Verify downloaded bytes against the registry's sha256. Empty
/// expected hash = unverifiable = rejected. Never optional.
bool verifySha256(List<int> bytes, String expectedHex) {
  if (expectedHex.isEmpty) return false;
  final digest = sha256.convert(bytes).toString();
  return digest.toLowerCase() == expectedHex.toLowerCase();
}

Future<List<RegistryEntry>> _readCached(File bodyFile) async {
  try {
    if (!await bodyFile.exists()) return const [];
    return _parse(await bodyFile.readAsString());
  } catch (_) {
    try {
      await bodyFile.delete();
    } catch (_) {}
    return const [];
  }
}

List<RegistryEntry> _parse(String body) {
  try {
    final m = jsonDecode(body) as Map;
    final list = (m['extensions'] as List?) ?? [];
    return [
      for (final e in list)
        if (e is Map && RegistryEntry.fromJson(e) != null)
          RegistryEntry.fromJson(e)!,
    ];
  } catch (_) {
    return const [];
  }
}

Future<Directory> _dir() async {
  final base = await needleBaseDir();
  final dir = Directory('${base.path}/registry');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

String _keyOf(String url) =>
    url.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
