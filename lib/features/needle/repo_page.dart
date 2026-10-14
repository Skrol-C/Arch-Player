import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import 'needle_store.dart';
import 'registry_browse.dart';

/// Extension repositories: the community registry preloaded, user
/// repos alongside. Real persisted state; browsing/installing
/// arrives with the engine slice and lights up this same list.
class RepoPage extends ConsumerWidget {
  const RepoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(repoUrlsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Repositories')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          const Text(
            'Registries of Needle extensions. The community registry ships preloaded; add more to reach other providers. Tap one to browse and install.',
            style: TextStyle(color: inkDim, height: 1.5),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < repos.length; i++)
            _RepoRow(
              url: repos[i],
              isDefault: i == 0 && repos[i] == NeedlePrefs.defaultRegistry,
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _addDialog(context, ref),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add repository'),
          ),
          TextButton(
            onPressed: () async {
              HapticFeedback.selectionClick();
              await ref.read(repoUrlsProvider.notifier).resetDefault();
              ArchLog.i('needle', 'repos reset to default');
            },
            child: const Text(
              'Reset to default',
              style: TextStyle(color: archPink),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add repository'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'https://.../registry.json',
            helperText: 'HTTPS registry index, hash-verified on install.',
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add', style: TextStyle(color: archPink)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null) return;
    final v = url.trim();
    if (!v.startsWith('https://')) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Repositories must use HTTPS.')),
      );
      return;
    }
    HapticFeedback.selectionClick();
    await ref.read(repoUrlsProvider.notifier).add(v);
    ArchLog.i('needle', 'repo added');
  }
}

class _RepoRow extends ConsumerWidget {
  final String url;
  final bool isDefault;

  const _RepoRow({required this.url, required this.isDefault});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: paperRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Text(
          url,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: isDefault
            ? const Text(
                'Community default',
                style: TextStyle(color: archPink, fontSize: 12),
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Browse',
              icon: const Icon(Icons.explore_outlined, color: archPink),
              onPressed: () {
                HapticFeedback.selectionClick();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RegistryBrowsePage(url: url),
                ));
              },
            ),
            if (!isDefault)
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded,
                    color: inkDim),
                onPressed: () async {
                  HapticFeedback.selectionClick();
                  await ref
                      .read(repoUrlsProvider.notifier)
                      .remove(url);
                  ArchLog.i('needle', 'repo removed');
                },
              ),
          ],
        ),
      ),
    );
  }
}
