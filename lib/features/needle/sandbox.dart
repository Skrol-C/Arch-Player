import 'dart:convert';

import '../../core/log.dart';
import 'bridge/api.dart' as bridge;
import 'needle_core.dart';

/// Typed error for everything sandbox-shaped: JS errors, timeouts,
/// oversize inputs, bridge failures. Callers switch on [code],
/// never on message text.
class NeedleException implements Exception {
  final String code;
  final String message;

  const NeedleException(this.code, this.message);

  @override
  String toString() => 'NeedleException($code): $message';
}

/// Run extension JS in the Rust sandbox: pure compute over
/// [inputJson], JSON envelope back. Budgets enforced inside the
/// runtime (timeout) and at the door (1MB caps both ways).
/// Rides the extension path with deny-all caps and unused dirs -
/// one code path, no special cases.
Future<Map<String, dynamic>> runSandbox(
  String source,
  Map<String, dynamic> input, {
  int timeoutMs = 5000,
}) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  late final String raw;
  try {
    raw = await bridge.needleExtensionCall(
      source: source,
      inputJson: jsonEncode(input),
      timeoutMs: timeoutMs,
      allowHostsJson: '[]',
      storageDir: '',
      filesDir: '',
      namespace: 'pure',
    );
  } catch (e) {
    throw NeedleException('bridge-error', '$e');
  }
  Map<String, dynamic> envelope;
  try {
    envelope = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    throw const NeedleException('bad-envelope', 'Sandbox reply unparseable');
  }
  if (envelope['ok'] != true) {
    final err = (envelope['error'] as String?) ?? 'unknown';
    final code = err.contains('imeout') ? 'timeout' : 'script-error';
    ArchLog.w('needle', 'sandbox $code: $err');
    throw NeedleException(code, err);
  }
  return envelope;
}

/// Extension call: sandboxed JS with host capabilities (http
/// allowlist, namespaced storage, scoped files, call logs).
/// `allowHosts` fails closed (empty = deny all). Logs ride the
/// envelope under `logs`; host denials surface as
/// `extension-error` with the Rust reason, never as crashes.
Future<Map<String, dynamic>> runExtension(
  String source,
  Map<String, dynamic> input, {
  List<String> allowHosts = const [],
  required String storageDir,
  required String filesDir,
  required String namespace,
  int timeoutMs = 10000,
}) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  late final String raw;
  try {
    raw = await bridge.needleExtensionCall(
      source: source,
      inputJson: jsonEncode(input),
      timeoutMs: timeoutMs,
      allowHostsJson: jsonEncode(allowHosts),
      storageDir: storageDir,
      filesDir: filesDir,
      namespace: namespace,
    );
  } catch (e) {
    throw NeedleException('bridge-error', '$e');
  }
  Map<String, dynamic> envelope;
  try {
    envelope = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    throw const NeedleException('bad-envelope', 'Extension reply unparseable');
  }
  if (envelope['ok'] != true) {
    final err = (envelope['error'] as String?) ?? 'unknown';
    ArchLog.w('needle', 'extension error: $err');
    throw NeedleException('extension-error', err);
  }
  return envelope;
}
