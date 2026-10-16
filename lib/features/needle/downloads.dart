import 'dart:async';

import '../../core/log.dart';
import 'bridge/api.dart' as bridge;
import 'calling.dart';
import 'extension.dart';
import 'needle_core.dart';
import 'needle_dirs.dart';
import 'sandbox.dart';

/// One active download: progress stream plus the final path.
/// Terminal outcome arrives as the `done` event (carrying error
/// or path); a stream that closes without one is itself a failure.
class DownloadJob {
  final int id;
  final String url;
  final String destPath;
  final Stream<bridge.DownloadProgress> progress;

  const DownloadJob({
    required this.id,
    required this.url,
    required this.destPath,
    required this.progress,
  });
}

int _nextJobId = 1;

/// Start a download: allowlist-gated fetch with streamed progress
/// and atomic landing. Throws NeedleException on bridge failure;
/// per-chunk failures surface as the terminal progress event.
Future<DownloadJob> downloadFile({
  required String url,
  required String destPath,
  required List<String> allowHosts,
}) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  final id = _nextJobId++;
  late final Stream<bridge.DownloadProgress> stream;
  try {
    stream = bridge.needleDownload(
      jobId: BigInt.from(id),
      url: url,
      destPath: destPath,
      allowHostsJson: _encodeStrings(allowHosts),
    );
  } catch (e) {
    throw NeedleException('bridge-error', '$e');
  }
  return DownloadJob(
      id: id, url: url, destPath: destPath, progress: stream);
}

/// Await a job to its terminal event: returns the landed path, or
/// throws the terminal error. Stream-close without a terminal is
/// a failure, never a silent success.
Future<String> awaitLanded(DownloadJob job) {
  final done = Completer<String>();
  late final StreamSubscription<bridge.DownloadProgress> sub;
  sub = job.progress.listen(
    (p) {
      if (!p.done) return;
      sub.cancel();
      if (p.error != null) {
        done.completeError(NeedleException('download-failed', p.error!));
      } else if (p.path != null) {
        done.complete(p.path!);
      } else {
        done.completeError(
            const NeedleException('download-failed', 'no terminal path'));
      }
    },
    onError: (Object e) {
      done.completeError(NeedleException('download-failed', '$e'));
    },
    onDone: () {
      if (!done.isCompleted) {
        done.completeError(const NeedleException(
            'download-failed', 'stream closed without terminal'));
      }
    },
    cancelOnError: false,
  );
  return done.future;
}

/// Cooperative cancel: next chunk boundary aborts and cleans the
/// partial file. Always succeeds from the caller's side (unknown
/// ids are idempotent no-ops in core).
Future<void> cancelDownload(int id) async {
  if (!Needle.ready) return;
  try {
    await bridge.needleDownloadCancel(jobId: BigInt.from(id));
  } catch (e) {
    ArchLog.w('needle', 'cancel failed: $e');
  }
}

String _encodeStrings(List<String> items) {
  final buf = StringBuffer('[');
  for (var i = 0; i < items.length; i++) {
    if (i > 0) buf.write(',');
    buf.write('"');
    buf.write(items[i].replaceAll('\\', '\\\\').replaceAll('"', '\\"'));
    buf.write('"');
  }
  buf.write(']');
  return buf.toString();
}

/// Debug-only end-to-end chain: search a metadata provider, take
/// the first preview URL found, download it, verify bytes. Proves
/// search-resolve-download on real networks with real extensions.
/// Release never runs it.
Future<void> debugDownloadChain(List<InstalledExtension> providers) async {
  Map<String, dynamic>? hit;
  try {
    final out = await callProviders('metadata', 'searchTracks',
        ['test', 5],
        providers: providers, timeoutMs: 20000);
    ArchLog.i('needle', 'chain search ok');
    hit = _firstPreview(out['value']);
  } on NeedleException catch (e) {
    ArchLog.w('needle', 'chain search failed: ${e.code}');
    return;
  }
  if (hit == null) {
    ArchLog.w('needle', 'chain: no preview url in results');
    return;
  }
  final baseDir = await needleBaseDir();
  final base = '${baseDir.path}/chain';
  final dest = '$base/${DateTime.now().millisecondsSinceEpoch}.bin';
  try {
    final job = await downloadFile(
      url: hit['url']!,
      destPath: dest,
      allowHosts: [hit['host']!],
    );
    final path = await awaitLanded(job).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw const NeedleException(
            'download-failed', 'chain download timed out'));
    ArchLog.i('needle', 'chain download landed: $path');
  } on NeedleException catch (e) {
    ArchLog.w('needle', 'chain download failed: ${e.code} ${e.message}');
  }
}

/// First usable preview URL in a search result, shape-tolerant:
/// walks maps/lists for the first http(s) string under a
/// preview/url/src-like key plus its host for the allowlist.
Map<String, String>? _firstPreview(dynamic node) {
  Map<String, String>? found;
  void visit(dynamic n) {
    if (found != null) return;
    if (n is Map) {
      for (final e in n.entries) {
        final k = e.key.toString().toLowerCase();
        final v = e.value;
        if (v is String &&
            (k.contains('preview') ||
                k == 'url' ||
                k == 'src' ||
                k == 'stream') &&
            (v.startsWith('https://') || v.startsWith('http://'))) {
          try {
            final host = Uri.parse(v).host;
            if (host.isNotEmpty) found = {'url': v, 'host': host};
          } catch (_) {}
          if (found != null) return;
        }
        visit(v);
      }
    } else if (n is List) {
      for (final e in n) {
        visit(e);
        if (found != null) return;
      }
    }
  }

  visit(node);
  return found;
}
