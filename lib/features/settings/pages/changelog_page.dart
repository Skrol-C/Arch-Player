import 'package:flutter/material.dart';

import '../../../core/log.dart';
import '../changelog_store.dart';
import '../widgets/commit_row.dart';
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
                CommitRow(entry: entries[i]),
          );
        },
      ),
    );
  }
}
