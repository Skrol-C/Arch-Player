import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import 'needle_store.dart';
import 'packages.dart';
import 'registry.dart';

/// Registry browse: live extension list with install. Entries show
/// id, version, description; installed ones show state instead of
/// an install button. Explicit loading/error/empty/data.
class RegistryBrowsePage extends ConsumerStatefulWidget {
  final String url;
  const RegistryBrowsePage({super.key, required this.url});

  @override
  ConsumerState<RegistryBrowsePage> createState() =>
      _RegistryBrowsePageState();
}

class _RegistryBrowsePageState
    extends ConsumerState<RegistryBrowsePage> {
  late Future<List<RegistryEntry>> _future;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _future = fetchRegistry(widget.url);
  }

  Future<void> _install(RegistryEntry entry) async {
    if (_busy.contains(entry.id)) return;
    setState(() => _busy.add(entry.id));
    HapticFeedback.mediumImpact();
    try {
      final result = await installExtension(entry);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (result.ok && result.installed != null) {
        await ref
            .read(installedExtensionsProvider.notifier)
            .upsert(result.installed!);
        messenger.showSnackBar(
          SnackBar(
              content: Text('Installed ${result.installed!.displayName}')),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text('Install failed: ${result.reason}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = ref.watch(installedExtensionsProvider);
    final installedIds = installed.map((e) => e.id).toSet();
    return Scaffold(
      appBar: AppBar(title: const Text('Browse registry')),
      body: FutureBuilder<List<RegistryEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child:
                    CircularProgressIndicator(color: archPink));
          }
          if (snap.hasError) {
            ArchLog.w('needle', 'registry browse failed');
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_outlined,
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 64),
                  const SizedBox(height: 12),
                  const Text('Could not reach this registry.',
                      style: TextStyle(
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('Check the URL and your connection.',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant)),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => setState(() =>
                        _future = fetchRegistry(widget.url)),
                    child: const Text('Retry',
                        style: TextStyle(color: archPink)),
                  ),
                ],
              ),
            );
          }
          final entries = snap.data ?? [];
          if (entries.isEmpty) {
            return Center(
              child: Text('This registry lists no extensions.',
                  style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              final done = installedIds.contains(e.id);
              final busy = _busy.contains(e.id);
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 6),
                  title: Text(e.displayName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 13)),
                      const SizedBox(height: 2),
                      Text('v${e.version}',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 12)),
                    ],
                  ),
                  trailing: done
                      ? const Icon(Icons.check_circle,
                          color: archPink)
                      : busy
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                  color: archPink,
                                  strokeWidth: 2),
                            )
                          : TextButton(
                              onPressed: () => _install(e),
                              child: const Text('Install',
                                  style: TextStyle(
                                      color: archPink,
                                      fontWeight: FontWeight.w700)),
                            ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
