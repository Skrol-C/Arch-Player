import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/log.dart';
import '../changelog_store.dart';
import '../update_service.dart';
import '../widgets/commit_row.dart';
import '../widgets/setting_bits.dart';
import '../widgets/update_dialog.dart';
import 'changelog_page.dart';

/// Updates: version on top, check button, latest bundled changes.
/// The check hits GitHub releases when the repo is public; until
/// then it honestly says it could not reach it. A found update
/// opens the glass dialog, which owns download + install.
class UpdaterPage extends ConsumerStatefulWidget {
  const UpdaterPage({super.key});

  @override
  ConsumerState<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends ConsumerState<UpdaterPage> {
  bool _checking = false;
  bool _checked = false;
  bool _reachable = true;
  String _version = '';
  List<ChangelogEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final entries = await loadChangelog();
      if (mounted) {
        setState(() {
          _version =
              '${info.version}+${info.buildNumber}';
          _entries = entries;
        });
      }
    } catch (e) {
      ArchLog.w('updater', 'version read failed: $e');
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _checked = false;
    });
    ArchLog.i('updater', 'manual check requested');
    final result = await checkForUpdateDetailed(manual: true);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checked = true;
      _reachable = result.reached;
    });
    if (result.update != null) {
      await showUpdateDialog(context, info: result.update!);
    }
  }

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'updater open');
    final scheme = Theme.of(context).colorScheme;
    final latest = _entries.isEmpty ? null : _entries.first;
    return Scaffold(
      appBar: AppBar(title: const Text('Updates')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Material(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: _checking
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Icon(
                                Icons.system_update_rounded,
                                color: Color(0xFFFC3C44),
                                size: 28,
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              _version.isEmpty
                                  ? 'Arch Player'
                                  : 'Arch Player $_version',
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              _checking
                                  ? 'Checking…'
                                  : _checked
                                      ? (_reachable
                                          ? 'You are up to date'
                                          : 'Could not reach GitHub')
                                      : 'Check for the newest build',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _checking ? null : _check,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFC3C44),
                      ),
                      child: Text(
                        _checking
                            ? 'Checking…'
                            : 'Check for updates',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SettingGroup(
            title: 'Latest changes',
            children: [
              if (latest == null)
                SettingState.empty(
                  'No changelog bundled with this build.',
                )
              else ...[
                for (final e in _entries.take(5))
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16),
                    child: CommitRow(entry: e),
                  ),
                SettingRow(
                  icon: Icons.list_rounded,
                  title: 'Full changelog',
                  subtitle:
                      '${_entries.length} commits in this build',
                  push: const ChangelogPage(),
                ),
              ],
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Updates download from GitHub releases and install on '
              'this device, no store needed.',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
