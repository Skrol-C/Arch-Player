import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/library_providers.dart';

final _setupDoneProvider = FutureProvider<bool>((ref) {
  return ref.watch(folderStoreProvider).setupDone;
});

/// First-run front door: permission -> where's your music -> done.
/// Calm white pages, one decision each, skippable nowhere that matters.
class SetupGate extends ConsumerWidget {
  final Widget child;
  const SetupGate({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = ref.watch(_setupDoneProvider);
    return done.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator(color: archPink)),
      ),
      error: (e, _) => Scaffold(body: Center(child: Text('Setup failed: $e'))),
      data: (isDone) => isDone ? child : const _SetupFlow(),
    );
  }
}

class _SetupFlow extends ConsumerStatefulWidget {
  const _SetupFlow();

  @override
  ConsumerState<_SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends ConsumerState<_SetupFlow> {
  bool _musicOk = false;
  bool _checking = true;
  List<String> _suggestions = [];
  final Set<String> _chosen = {};

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    var status = await Permission.audio.status;
    if (!status.isGranted && !status.isLimited) {
      status = await Permission.audio.request();
      if (status.isDenied) status = await Permission.storage.request();
    }
    await Permission.notification.request();
    List<String> suggestions = [];
    if (status.isGranted ||
        status.isLimited ||
        (await Permission.storage.status).isGranted) {
      _musicOk = true;
      try {
        suggestions = await ref
            .read(libraryRepositoryProvider)
            .suggestFolders();
      } catch (e) {
        ArchLog.w('setup', 'suggestions failed: $e');
      }
      setState(() {
        _checking = false;
        _suggestions = suggestions;
        _chosen.addAll(suggestions);
      });
    } else {
      setState(() => _checking = false);
    }
  }

  Future<void> _pickCustom() async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Where is your music?',
      );
      if (path == null) return;
      setState(() => _chosen.add(path));
    } catch (e) {
      ArchLog.w('setup', 'custom pick failed: $e');
    }
  }

  Future<void> _finish() async {
    final store = ref.read(folderStoreProvider);
    for (final p in _chosen) {
      await store.addPicked(p);
    }
    ArchLog.i('setup', 'done with ${_chosen.length} folders');
    await store.setSetupDone();
    ref.invalidate(_setupDoneProvider);
    ref.invalidate(songsProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: archPink)),
      );
    }
    if (!_musicOk) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Arch needs\nyour music',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Allow access to keep going - nothing leaves your phone.',
                  style: TextStyle(color: inkDim, height: 1.5),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _boot,
                  child: const Text('Allow music access'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FocalEntrance(
                child: Text(
                  'Where\u2019s\nyour music?',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Arch only looks where you point it. Add more folders anytime.',
                style: TextStyle(color: inkDim, height: 1.5),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView(
                  children: [
                    for (final s in _suggestions)
                      CheckboxListTile(
                        title: Text(s),
                        value: _chosen.contains(s),
                        activeColor: archPink,
                        onChanged: (on) => setState(() {
                          if (on == true) {
                            _chosen.add(s);
                          } else {
                            _chosen.remove(s);
                          }
                        }),
                      ),
                    for (final c in _chosen.where(
                      (c) => !_suggestions.contains(c),
                    ))
                      ListTile(
                        title: Text(c),
                        trailing: const Icon(
                          Icons.check_circle,
                          color: archPink,
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: _pickCustom,
                      icon: const Icon(Icons.create_new_folder_rounded),
                      label: const Text('Choose another folder'),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _chosen.isEmpty ? null : _finish,
                  child: Text(
                    _chosen.isEmpty
                        ? 'Pick at least one folder'
                        : 'Start listening (${_chosen.length})',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
