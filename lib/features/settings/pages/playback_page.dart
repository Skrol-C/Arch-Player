import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/log.dart';
import '../../archfm/archfm_providers.dart';
import '../../player/player_providers.dart';
import '../widgets/arch_switch.dart';
import '../widgets/setting_bits.dart';

/// Playback: the automix home. Master switch plus the queue
/// behaviours the engine actually reads. Every toggle here flips
/// real persisted state, no decor.
class PlaybackPage extends ConsumerWidget {
  const PlaybackPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'playback settings open');
    final automix = ref.watch(autoMixProvider);
    final autoplay = ref.watch(autoPlayProvider);
    final shuffle = ref.watch(shuffleProvider);
    final loop = ref.watch(loopProvider);
    final engine = ref.watch(kokoroEngineProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Automix',
            children: [
              _ToggleRow(
                icon: Icons.tune_rounded,
                title: 'Automix',
                subtitle: automix
                    ? 'On, harmonic flow between tracks'
                    : 'Off, tracks play as queued',
                value: automix,
                onChanged: (_) =>
                    ref.read(autoMixProvider.notifier).toggle(),
              ),
            ],
          ),
          SettingGroup(
            title: 'Queue',
            children: [
              _ToggleRow(
                icon: Icons.shuffle_rounded,
                title: 'Shuffle',
                subtitle: shuffle
                    ? 'On, queue plays shuffled'
                    : 'Off, queue plays in order',
                value: shuffle,
                onChanged: (_) =>
                    ref.read(shuffleProvider.notifier).toggle(),
              ),
              _ToggleRow(
                icon: Icons.playlist_play_rounded,
                title: 'Autoplay',
                subtitle: autoplay
                    ? 'On, compatible tracks keep coming'
                    : 'Off, stops when the queue ends',
                value: autoplay,
                onChanged: (_) =>
                    ref.read(autoPlayProvider.notifier).toggle(),
              ),
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.repeat_rounded,
                    color: Color(0xFFFC3C44),
                  ),
                ),
                title: const Text(
                  'Repeat',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  switch (loop) {
                    LoopMode.off => 'Off',
                    LoopMode.one => 'This track',
                    LoopMode.all => 'Whole queue',
                  },
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                trailing: TextButton(
                  onPressed: () =>
                      ref.read(loopProvider.notifier).cycle(),
                  child: const Text('Change'),
                ),
                onTap: () =>
                    ref.read(loopProvider.notifier).cycle(),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Automix hands off between harmonically compatible '
              'tracks with a beat-matched bridge. One tap off, '
              'always. The switch never disagrees with the engine.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          SettingGroup(
            title: 'Arch-FM voice',
            children: [
              _EngineRow(engine: engine),
              if (engine.status == EngineStatus.ready)
                SettingRow(
                  icon: Icons.delete_outline_rounded,
                  title: 'Remove engine',
                  subtitle: 'Frees about 345 MB, breaks go silent',
                  onTap: () {
                    ref.read(kokoroEngineProvider.notifier).remove();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Voice engine removed'),
                      ),
                    );
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              '305 MB download, use Wi-Fi. The engine renders the '
              'hosts on your phone, no cloud, removable anytime.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: const Color(0xFFFC3C44)),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
      trailing: ArchSwitch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );
  }
}

/// Voice engine row: install progress, cancel, retry, or the
/// installed state. One row, no dead ends: every status taps to
/// something real.
class _EngineRow extends ConsumerWidget {
  final EngineState engine;

  const _EngineRow({required this.engine});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (title, subtitle) = switch (engine.status) {
      EngineStatus.missing => (
        'Voice engine',
        'Not installed, 305 MB download',
      ),
      EngineStatus.downloading => (
        'Downloading',
        '${(engine.progress * 100).round()} percent, tap to cancel',
      ),
      EngineStatus.extracting => ('Unpacking', 'Unpacking voices'),
      EngineStatus.ready => (
        'Voice engine',
        engine.note.isEmpty
            ? 'Installed, Bella and Michael ready'
            : engine.note,
      ),
      EngineStatus.failed => ('Voice engine', engine.note),
    };
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: engine.status == EngineStatus.downloading
            ? Padding(
                padding: const EdgeInsets.all(10),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: const Color(0xFFFC3C44),
                  value: engine.progress > 0 ? engine.progress : null,
                ),
              )
            : const Icon(
                Icons.record_voice_over_rounded,
                color: Color(0xFFFC3C44),
              ),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
      trailing: engine.status == EngineStatus.ready
          ? Icon(
              CupertinoIcons.check_mark_circled_solid,
              color: scheme.primary,
            )
          : null,
      onTap: () {
        final notifier = ref.read(kokoroEngineProvider.notifier);
        switch (engine.status) {
          case EngineStatus.missing:
          case EngineStatus.failed:
            notifier.install();
          case EngineStatus.downloading:
          case EngineStatus.extracting:
            notifier.cancel();
          case EngineStatus.ready:
            break;
        }
      },
    );
  }
}
