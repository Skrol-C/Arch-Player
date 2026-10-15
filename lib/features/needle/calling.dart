import '../../core/log.dart';
import 'extension.dart';
import 'extensions.dart';
import 'needle_core.dart';
import 'sandbox.dart';

/// Call a named entry across providers with priority fall-through:
/// enabled extensions offering [role], in priority order, first
/// ok wins. Every skip/failure is logged with its reason - silent
/// fall-through is a debugging black hole. Callers supply the
/// installed list (the store owns it); the driver only reads.
/// Args follow the extension convention: searchTracks takes a
/// positional query string plus limit - see [searchArgs].
/// Entry fallbacks: providers that lack the requested entry are
/// tried under compatible aliases with adapted args. amazon (and
/// friends) expose customSearch instead of searchTracks.
const _entryFallbacks = {
  'searchTracks': ['customSearch'],
};

/// Adapted args per fallback entry: customSearch takes
/// (query, {limit}) where searchTracks takes (query, limit).
dynamic _fallbackArgs(String entry, dynamic args) {
  if (entry == 'customSearch' && args is List && args.isNotEmpty) {
    final query = args[0];
    final limit = args.length > 1 ? args[1] : 20;
    return [
      query,
      {'limit': limit is int ? limit : 20}
    ];
  }
  return args;
}

Future<Map<String, dynamic>> callProviders(
  String role,
  String entry,
  dynamic args, {
  required List<InstalledExtension> providers,
  int timeoutMs = 15000,
}) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  final candidates = [
    for (final e in providers)
      if (e.enabled && e.roles.contains(role)) e,
  ]..sort((a, b) => a.priority.compareTo(b.priority));
  if (candidates.isEmpty) {
    throw NeedleException(
        'no-provider', 'No enabled $role provider installed');
  }
  NeedleException? last;
  for (final e in candidates) {
    final entries = [entry, ...?_entryFallbacks[entry]];
    var called = false;
    for (final en in entries) {
      try {
        final h = await loadExtension(e.id);
        final fns = await extensionFunctions(h.handle);
        if (!fns.contains(en)) continue;
        called = true;
        final out = await callExtensionFn(h.handle, en,
            en == entry ? args : _fallbackArgs(en, args),
            timeoutMs: timeoutMs);
        ArchLog.i('needle', '$role $en via ${e.id}: ok');
        return out;
      } on NeedleException catch (err) {
        final detail = err.message.length > 300
            ? '${err.message.substring(0, 300)}...'
            : err.message;
        ArchLog.w('needle',
            '$role $en via ${e.id} failed: ${err.code}: $detail');
        last = err;
        continue;
      }
    }
    if (!called) {
      ArchLog.w('needle',
          '$role $entry via ${e.id} skipped: no compatible entry');
      last = NeedleException(
          'no-entry', 'No compatible entry in ${e.id}');
    }
  }
  throw last ??
      NeedleException(
          'no-provider', 'All $role providers failed');
}
