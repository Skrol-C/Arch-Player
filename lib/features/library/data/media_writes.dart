import 'package:flutter/services.dart';

import '../../../core/log.dart';

/// Outcome of a write, honest about *why* it failed.
enum WriteOutcome {
  ok,

  /// The OS asked the user and they said no (or the dialog was
  /// dismissed). Not an error, and not retryable without asking again.
  denied,

  /// The write was attempted and did not work — a missing file, a row
  /// that no longer exists, a path we cannot touch at all.
  failed,
}

/// Write side of the library channel: delete, retag, and the consent
/// prompt that makes either possible on files we did not publish.
///
/// Our own MediaStore inserts (Needle pulls) need no permission. Rows we
/// do not own raise RecoverableSecurityException natively, which arrives
/// here as a plain `false`; the *WithConsent helpers then ask once via
/// requestWriteAccess and retry. Nothing here throws.
class MediaWrites {
  static const _channel = MethodChannel('arch.player/library');

  static Future<bool> delete({required String uri, String path = ''}) async {
    if (uri.isEmpty && path.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('deleteAudio', {
            'uri': uri,
            'path': path,
          }) ??
          false;
    } catch (e) {
      ArchLog.w('write', 'delete failed: $e');
      return false;
    }
  }

  /// Replace a row's bytes with a freshly tagged copy at [srcPath].
  static Future<bool> retag({
    required String uri,
    required String srcPath,
    String path = '',
  }) async {
    if (uri.isEmpty || srcPath.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('retagAudio', {
            'uri': uri,
            'srcPath': srcPath,
            'path': path,
          }) ??
          false;
    } catch (e) {
      ArchLog.w('write', 'retag failed: $e');
      return false;
    }
  }

  /// Ask the OS for write access to [uris]. One prompt covers them all.
  static Future<bool> requestWriteAccess(List<String> uris) async {
    final wanted = [for (final u in uris) if (u.isNotEmpty) u];
    if (wanted.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'requestWriteAccess', {'uris': wanted},
          ) ??
          false;
    } catch (e) {
      ArchLog.w('write', 'consent request failed: $e');
      return false;
    }
  }

  /// Delete, asking for consent only when the row is not ours.
  static Future<WriteOutcome> deleteWithConsent({
    required String uri,
    String path = '',
  }) async {
    if (await delete(uri: uri, path: path)) return WriteOutcome.ok;
    if (uri.isEmpty) return WriteOutcome.failed;
    ArchLog.i('write', 'delete needs consent: $uri');
    if (!await requestWriteAccess([uri])) return WriteOutcome.denied;
    return await delete(uri: uri, path: path)
        ? WriteOutcome.ok
        : WriteOutcome.failed;
  }

  /// Retag, asking for consent only when the row is not ours.
  static Future<WriteOutcome> retagWithConsent({
    required String uri,
    required String srcPath,
    String path = '',
  }) async {
    if (await retag(uri: uri, srcPath: srcPath, path: path)) {
      return WriteOutcome.ok;
    }
    if (uri.isEmpty) return WriteOutcome.failed;
    ArchLog.i('write', 'retag needs consent: $uri');
    if (!await requestWriteAccess([uri])) return WriteOutcome.denied;
    return await retag(uri: uri, srcPath: srcPath, path: path)
        ? WriteOutcome.ok
        : WriteOutcome.failed;
  }
}
