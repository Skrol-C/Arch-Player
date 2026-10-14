import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import 'bridge/api.dart' as bridge;
import 'bridge/frb_generated.dart';
import 'sandbox.dart';

/// Needle core lifecycle: init the Rust bridge once, verify with a
/// ping, and degrade honestly. Every caller checks [ready] first:
/// downloads require the bridge, everything else never does.
abstract final class Needle {
  static bool _ready = false;

  static bool get ready => _ready;

  static Future<bool> ensureReady() async {
    if (_ready) return true;
    try {
      await NeedleCore.init();
      final echo = await bridge.needlePing(nonce: 'boot');
      _ready = echo == 'needle-ok:boot';
      ArchLog.i(
        'needle',
        'bridge ${_ready ? 'ready' : 'ping mismatch'} ($echo)',
      );
      if (_ready) {
        // Sandbox self-test: round-trip, JS-error-as-data, timeout.
        // Logged, never trusted blindly; failures degrade to
        // bridge-down for every caller.
        try {
          final selftest = await bridge.needleSelftest();
          ArchLog.i('needle', 'selftest: $selftest');
        } catch (e) {
          ArchLog.w('needle', 'selftest failed: $e');
        }
        // Host-function smoke (debug only): storage round-trip,
        // allowlist denial, and log capture through the real
        // extension path on real ARM. Release skips it.
        if (kDebugMode) {
          try {
            final base =
                '${(await getApplicationCacheDirectory()).path}/needle_smoke';
            final env = await runExtension(
              'JSON.stringify({stored: JSON.parse(__needle_store_set("k", JSON.stringify({a:1}))).ok, read: JSON.parse(__needle_store_get("k")).value.a, denied: JSON.parse(__needle_http("https://example.com/")).error, logged: (__needle_log("smoke"), 1)})',
              const {},
              storageDir: '$base/store',
              filesDir: '$base/files',
              namespace: 'smoke',
            );
            ArchLog.i('needle', 'host smoke: ${env['value']} logs=${env['logs']}');
          } catch (e) {
            ArchLog.w('needle', 'host smoke failed: $e');
          }
        }
      }
    } catch (e) {
      ArchLog.w('needle', 'bridge unavailable: $e');
      _ready = false;
    }
    return _ready;
  }
}
