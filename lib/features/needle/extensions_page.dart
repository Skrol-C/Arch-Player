import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import 'extension.dart';
import 'extension_settings.dart';
import 'needle_store.dart';
import 'packages.dart';

/// Extensions hub: installed list, provider priority, settings,
/// and uninstall. Empty states are honest - install/browse
/// fills these same sections with zero UI changes.
class ExtensionsPage extends ConsumerWidget {
  const ExtensionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedExtensionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Extensions')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          const Text(
            'Providers plug in here: search, downloads, lyrics. Each runs sandboxed with only the permissions it declares.',
            style: TextStyle(color: inkDim, height: 1.5),
          ),
          const SizedBox(height: 16),
          const _SectionHead('Installed'),
          if (installed.isEmpty)
            const _EmptyNote(
              'No extensions yet. Add a repository, then browse it to install.',
            )
          else
            for (var i = 0; i < installed.length; i++)
              _ExtensionRow(
                  info: installed[i],
                  first: i == 0,
                  last: i == installed.length - 1),
          const SizedBox(height: 8),
          const _SectionHead('Provider priority'),
          const Text(
            'Top of the list answers first; failures fall through to the next. Reorder with the arrows.',
            style: TextStyle(color: inkDim, height: 1.5, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  final String text;
  const _SectionHead(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: inkDim,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  final String text;
  const _EmptyNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(text, style: const TextStyle(color: inkDim, height: 1.5)),
    );
  }
}

class _ExtensionRow extends ConsumerWidget {
  final InstalledExtension info;
  final bool first;
  final bool last;
  const _ExtensionRow(
      {required this.info, required this.first, required this.last});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: paperRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          SwitchListTile(
            title: Text(
              info.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${info.version}'
              '${info.roles.isEmpty ? '' : ' - ${info.roles.join(', ')}'}',
            ),
            value: info.enabled,
            activeThumbColor: archPink,
            onChanged: (on) async {
              HapticFeedback.selectionClick();
              await ref
                  .read(installedExtensionsProvider.notifier)
                  .setEnabled(info.id, on);
            },
          ),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () =>
                        _openSettings(context, ref, info),
                    child: const Text('Settings',
                        style: TextStyle(color: archPink)),
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward_rounded,
                      color: inkDim),
                  onPressed: first
                      ? null
                      : () => ref
                          .read(installedExtensionsProvider
                              .notifier)
                          .move(info.id, -1),
                ),
                IconButton(
                  tooltip: 'Move down',
                  icon: const Icon(Icons.arrow_downward_rounded,
                      color: inkDim),
                  onPressed: last
                      ? null
                      : () => ref
                          .read(installedExtensionsProvider
                              .notifier)
                          .move(info.id, 1),
                ),
                IconButton(
                  tooltip: 'Uninstall',
                  icon: const Icon(Icons.delete_outline_rounded,
                      color: inkDim),
                  onPressed: () =>
                      _confirmUninstall(context, ref, info),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmUninstall(
      BuildContext context, WidgetRef ref, InstalledExtension info) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Uninstall ${info.displayName}?'),
        content: const Text(
            'Removes its files and settings. Reinstall anytime from its repository.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Uninstall',
                style: TextStyle(color: archPink)),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    HapticFeedback.mediumImpact();
    await uninstallExtension(info.id);
    await ref
        .read(installedExtensionsProvider.notifier)
        .remove(info.id);
    ArchLog.i('needle', 'uninstalled ${info.id}');
  }

  Future<void> _openSettings(
      BuildContext context, WidgetRef ref, InstalledExtension info) async {
    HapticFeedback.selectionClick();
    final manifest = await readInstalledManifest(info.id);
    if (!context.mounted) return;
    if (manifest == null || manifest.settings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('This extension has no settings.')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ExtensionSettingsPage(manifest: manifest),
    ));
  }
}
