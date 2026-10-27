import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/log.dart';
import '../widgets/setting_bits.dart';

/// Remembered network locations. Persisted, add/remove/validate —
/// streaming playback against them lands with the network engine,
/// and until then this list is the honest saved set, never a fake
/// connected state.
final networkLocationsProvider =
    NotifierProvider<NetworkLocationsNotifier, List<String>>(
      NetworkLocationsNotifier.new,
    );

class NetworkLocationsNotifier extends Notifier<List<String>> {
  static const _key = 'arch.networkLocations';

  @override
  List<String> build() {
    _sync();
    return const [];
  }

  Future<void> _sync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getStringList(_key) ?? const [];
    } catch (_) {}
  }

  Future<void> add(String url) async {
    if (state.contains(url)) return;
    state = [...state, url];
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        _key,
        state,
      );
    } catch (_) {}
    ArchLog.i('settings', 'network location added: $url');
  }

  Future<void> remove(String url) async {
    state = state.where((u) => u != url).toList();
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        _key,
        state,
      );
    } catch (_) {}
    ArchLog.i('settings', 'network location removed: $url');
  }
}

class NetworkStoragePage extends ConsumerWidget {
  const NetworkStoragePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'network storage open');
    final locations = ref.watch(networkLocationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Network storage')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Locations',
            children: [
              if (locations.isEmpty)
                SettingState.empty(
                  'No network locations yet. Add a server or shared '
                  'folder URL to keep it here for the network engine.',
                )
              else
                for (final url in locations)
                  SettingRow(
                    icon: Icons.dns_rounded,
                    title: url,
                    subtitle: 'Remembered — streaming arrives '
                        'with the network engine',
                    trailing: IconButton(
                      tooltip: 'Forget',
                      onPressed: () => ref
                          .read(networkLocationsProvider.notifier)
                          .remove(url),
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              SettingRow(
                icon: Icons.add_link_rounded,
                title: 'Add location',
                subtitle: 'http(s) or smb URL',
                onTap: () => _add(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    final controller = TextEditingController();
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add location'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://music.home/library',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty) return;
    final uri = Uri.tryParse(next);
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'smb')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter an http(s) or smb URL'),
          ),
        );
      }
      return;
    }
    await ref.read(networkLocationsProvider.notifier).add(next);
  }
}
