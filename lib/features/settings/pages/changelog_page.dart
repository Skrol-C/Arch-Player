import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/log.dart';
import '../changelog_store.dart';
import '../widgets/setting_bits.dart';

/// Changelog: every bundled commit, newest first. Faces load from
/// GitHub with a disk cache and fall back to initials offline.
/// Shown both standalone and inside the updater, pre/post update.
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  late final Future<List<ChangelogEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = loadChangelog();
  }

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'changelog open');
    return Scaffold(
      appBar: AppBar(title: const Text('What’s new')),
      body: FutureBuilder<List<ChangelogEntry>>(
        future: _entries,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [SettingState.loading('Reading history…')],
            );
          }
          if (snap.hasError) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                SettingState.error(
                  'Could not read the changelog.',
                  retry: () => setState(() {
                    _entries = loadChangelog();
                  }),
                ),
              ],
            );
          }
          final entries = snap.data ?? const [];
          if (entries.isEmpty) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                SettingState.empty(
                  'No changelog bundled with this build.',
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            itemCount: entries.length,
            itemBuilder: (context, i) =>
                _EntryRow(entry: entries[i]),
          );
        },
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  final ChangelogEntry entry;

  const _EntryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = entry.author.isEmpty
        ? '?'
        : entry.author.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 36,
              height: 36,
              child: entry.author.isEmpty
                  ? _FallbackFace(initial: initial)
                  : CachedNetworkImage(
                      imageUrl: entry.avatarUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          _FallbackFace(initial: initial),
                      errorWidget: (_, _, _) =>
                          _FallbackFace(initial: initial),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.message,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.short} · ${entry.author} · ${entry.date}',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackFace extends StatelessWidget {
  final String initial;

  const _FallbackFace({required this.initial});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
