import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import 'extension.dart';
import 'needle_dirs.dart';
import 'registry.dart';

/// Package install: fetch, hash-verify, safety-scan, extract,
/// record. Every step fails closed with a typed reason - a bad
/// package never half-installs. Mirrors the community store
/// contract (zip layout, manifest at root) with original code.
class PackageResult {
  final bool ok;
  final String reason;
  final InstalledExtension? installed;

  const PackageResult._(this.ok, this.reason, this.installed);

  factory PackageResult.ok(InstalledExtension e) =>
      PackageResult._(true, '', e);
  factory PackageResult.fail(String reason) =>
      PackageResult._(false, reason, null);
}

/// Install from a registry entry: download, verify sha256, scan,
/// extract, record. Overwrites same-id installs (upgrade path).
Future<PackageResult> installExtension(RegistryEntry entry) async {
  List<int> bytes;
  try {
    final res = await http
        .get(Uri.parse(entry.downloadUrl))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      return PackageResult.fail('download failed (${res.statusCode})');
    }
    bytes = res.bodyBytes;
  } catch (e) {
    ArchLog.w('needle', 'extension download failed: $e');
    return PackageResult.fail('download failed');
  }
  if (!verifySha256(bytes, entry.sha256)) {
    ArchLog.w('needle', 'extension hash mismatch: ${entry.id}');
    return PackageResult.fail('hash mismatch - package rejected');
  }
  return installBytes(entry.id, bytes,
      displayName: entry.displayName,
      version: entry.version,
      description: entry.description);
}

/// Install from raw bytes (registry-verified or manually imported).
/// Manual imports carry no registry trust - callers label them.
Future<PackageResult> installBytes(
  String id,
  List<int> bytes, {
  String? displayName,
  String? version,
  String? description,
}) async {
  // Size caps: packages stay small; extraction stays bounded.
  if (bytes.isEmpty || bytes.length > 64 * 1024 * 1024) {
    return PackageResult.fail('package size out of bounds');
  }
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return PackageResult.fail('not a valid package');
  }
  // Safety scan BEFORE extraction: no absolute paths, no escapes,
  // no symlinks-by-name, manifest + entry script at root.
  var hasManifest = false;
  var hasScript = false;
  for (final f in archive.files) {
    final name = f.name.replaceAll('\\', '/');
    if (name.startsWith('/') ||
        name.contains('..') ||
        name.startsWith('./')) {
      return PackageResult.fail('unsafe paths in package');
    }
    if (name == 'manifest.json') hasManifest = true;
    if (name == 'index.js') hasScript = true;
    if (f.size > 64 * 1024 * 1024) {
      return PackageResult.fail('entry too large');
    }
  }
  if (!hasManifest || !hasScript) {
    return PackageResult.fail('missing manifest or entry script');
  }
  Map manifestJson;
  try {
    final raw = archive.files
        .firstWhere((f) => f.name.replaceAll('\\', '/') == 'manifest.json');
    manifestJson = jsonDecode(String.fromCharCodes(raw.content)) as Map;
  } catch (_) {
    return PackageResult.fail('unreadable manifest');
  }
  final manifest = ExtensionManifest.parse(manifestJson);
  if (manifest == null) {
    return PackageResult.fail('invalid manifest');
  }
  if (manifest.name != id && id.isNotEmpty) {
    ArchLog.w('needle',
        'extension id mismatch: registry $id vs manifest ${manifest.name}');
    return PackageResult.fail('id mismatch');
  }
  // Extract into a fresh staging dir, then atomically swap: a
  // failed install never leaves a half-written extension behind.
  try {
    final base = await _extDir();
    final staging = Directory('${base.path}/.${manifest.name}.staging');
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    for (final f in archive.files) {
      final name = f.name.replaceAll('\\', '/');
      if (name.endsWith('/')) continue;
      final out = File('${staging.path}/$name');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>, flush: true);
    }
    final dest = Directory('${base.path}/${manifest.name}');
    if (await dest.exists()) await dest.delete(recursive: true);
    await staging.rename(dest.path);
    ArchLog.i('needle', 'installed ${manifest.name} ${manifest.version}');
  } catch (e) {
    ArchLog.w('needle', 'extension extract failed: $e');
    return PackageResult.fail('extract failed');
  }
  final roles = <String>[
    if (manifest.isMetadata) 'metadata',
    if (manifest.isDownload) 'download',
    if (manifest.isLyrics) 'lyrics',
  ];
  return PackageResult.ok(InstalledExtension(
    id: manifest.name,
    displayName: displayName ?? manifest.displayName,
    version: version ?? manifest.version,
    description: description ?? manifest.description,
    roles: roles,
  ));
}

/// Remove an installed extension entirely: files + record.
Future<bool> uninstallExtension(String id) async {
  try {
    final base = await _extDir();
    final dest = Directory('${base.path}/$id');
    if (await dest.exists()) await dest.delete(recursive: true);
    ArchLog.i('needle', 'uninstalled $id');
    return true;
  } catch (e) {
    ArchLog.w('needle', 'uninstall failed: $e');
    return false;
  }
}

/// Read an installed manifest back from disk. Null when missing
/// or invalid - the record survives, the detail doesn't lie.
Future<ExtensionManifest?> readInstalledManifest(String id) async {
  try {
    final base = await _extDir();
    final file = File('${base.path}/$id/manifest.json');
    if (!await file.exists()) return null;
    final m = jsonDecode(await file.readAsString()) as Map;
    return ExtensionManifest.parse(m);
  } catch (_) {
    return null;
  }
}

/// Read an installed entry script. Null when missing.
Future<String?> readInstalledScript(String id) async {
  try {
    final base = await _extDir();
    final file = File('${base.path}/$id/index.js');
    if (!await file.exists()) return null;
    return await file.readAsString();
  } catch (_) {
    return null;
  }
}

/// Installed directory for an extension id, or null when no
/// package (or no manifest) sits on disk. The driver loads from
/// here; Rust validates again on load.
Future<String?> extDirFor(String id) async {  if (id.isEmpty || id.contains(RegExp(r'[^a-z0-9._-]'))) return null;
  try {
    final base = await _extDir();
    final dir = Directory('${base.path}/$id');
    final manifest = File('${dir.path}/manifest.json');
    final script = File('${dir.path}/index.js');
    if (!await manifest.exists() || !await script.exists()) return null;
    return dir.path;
  } catch (_) {
    return null;
  }
}

/// Packages root (one subdir per installed id). The debug smoke
/// enumerates it; the driver resolves individual ids.
Future<Directory> extPackagesDir() async => _extDir();

Future<Directory> _extDir() async {
  final base = await needleBaseDir();
  final dir = Directory('${base.path}/extensions');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
