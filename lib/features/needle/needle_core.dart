import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import 'bridge/api.dart' as bridge;
import 'bridge/frb_generated.dart';
import 'downloads.dart';
import 'extension.dart';
import 'extensions.dart';
import 'needle_dirs.dart';
import 'packages.dart';
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
        // Storage moved out of evictable cache (extensions wiped
        // mid-session once): migrate, then run diagnostics.
        try {
          await migrateNeedleFromCache();
        } catch (e) {
          ArchLog.w('needle', 'cache migrate failed: $e');
        }
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
            final base = await needleBaseDir();
            final env = await runExtension(
              'JSON.stringify({stored: JSON.parse(__needle_store_set("k", JSON.stringify({a:1}))).ok, read: JSON.parse(__needle_store_get("k")).value.a, denied: JSON.parse(__needle_http("https://example.com/")).error, logged: (__needle_log("smoke"), 1)})',
              const {},
              storageDir: '${base.path}/smoke/store',
              filesDir: '${base.path}/smoke/files',
              namespace: 'smoke',
            );
            ArchLog.i('needle', 'host smoke: ${env['value']} logs=${env['logs']}');
          } catch (e) {
            ArchLog.w('needle', 'host smoke failed: $e');
          }
          // Installed-extension listing (debug only): loads every
          // installed package and logs its registered entries.
          // Proves real community extensions parse + register on
          // device. No network calls, no downloads.
          try {
            final dir = await extPackagesDir();
            if (await dir.exists()) {
              await for (final e in dir.list()) {
                final id = e.path.split(RegExp(r'[/\\]')).last;
                if (id.startsWith('.')) continue;
                try {
                  final h = await loadExtension(id);
                  final fns = await extensionFunctions(h.handle);
                  ArchLog.i('needle', 'ext $id fns=$fns');
                } catch (err) {
                  ArchLog.w('needle', 'ext $id load failed: $err');
                }
              }
            }
          } catch (e) {
            ArchLog.w('needle', 'ext listing failed: $e');
          }
          // End-to-end chain (debug only): real search through the
          // installed metadata providers, first preview URL
          // downloaded and verified. Positional (query, limit) per
          // the extension calling convention. The whole bet in one
          // log span.
          try {
            final prefs = await SharedPreferences.getInstance();
            final raw = prefs.getString('arch.extensions');
            final providers =
                raw == null ? const <InstalledExtension>[] : decodeInstalledList(raw);
            if (providers.any((e) =>
                e.enabled && e.roles.contains('metadata'))) {
              await debugDownloadChain(providers);
            } else {
              ArchLog.i('needle', 'chain skipped: no metadata provider');
            }
          } catch (e) {
            ArchLog.w('needle', 'chain failed: $e');
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
