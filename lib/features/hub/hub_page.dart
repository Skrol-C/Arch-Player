import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../archfm/archfm_providers.dart';
import '../archfm/archfm_service.dart';
import '../archfm/kokoro_voices.dart';
import '../archfm/liner_bank.dart';
import '../settings/widgets/arch_switch.dart';
import '../settings/widgets/setting_bits.dart';

/// Arch Hub: Buds-style systems page. Three pills above one
/// content pane: Arch Motion Audio, Arch Adaptive Audio, Arch-FM.
/// Motion and Adaptive are honest empty states until their engines
/// land. Arch-FM is fully wired: master switch, host voice,
/// preset, frequency, static bed, and a parked duo row.
class ArchHubPage extends ConsumerStatefulWidget {
  const ArchHubPage({super.key});

  @override
  ConsumerState<ArchHubPage> createState() => _ArchHubPageState();
}

enum _HubTab { motion, adaptive, fm }

class _ArchHubPageState extends ConsumerState<ArchHubPage> {
  _HubTab _tab = _HubTab.fm;

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'arch hub open');
    return Scaffold(
      appBar: AppBar(title: const Text('Arch Hub')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          _Pills(tab: _tab, onPick: (t) => setState(() => _tab = t)),
          const SizedBox(height: 8),
          switch (_tab) {
            _HubTab.fm => const _FmPane(),
            _HubTab.motion => SettingState.empty(
              'Motion Audio arrives with its engine. Nothing to tune yet.',
            ),
            _HubTab.adaptive => SettingState.empty(
              'Adaptive Audio arrives with its engine. Nothing to tune yet.',
            ),
          },
        ],
      ),
    );
  }
}

/// Three pills above the content: Motion, Adaptive, FM.
/// Selection is pink, the house color for selection.
class _Pills extends StatelessWidget {
  final _HubTab tab;
  final ValueChanged<_HubTab> onPick;

  const _Pills({required this.tab, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(_HubTab t, String label) {
      final selected = tab == t;
      return Expanded(
        child: GestureDetector(
          onTap: () => onPick(t),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.14)
                  : scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.12),
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: selected
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill(_HubTab.motion, 'Motion'),
        const SizedBox(width: 8),
        pill(_HubTab.adaptive, 'Adaptive'),
        const SizedBox(width: 8),
        pill(_HubTab.fm, 'FM'),
      ],
    );
  }
}

/// Arch-FM pane: every row flips real persisted state. The duo
/// row and the test-voice row degrade honestly while the native
/// engine is still on the way.
class _FmPane extends ConsumerWidget {
  const _FmPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = ref.watch(archFmEnabledProvider);
    final voice = ref.watch(archFmVoiceProvider);
    final preset = ref.watch(archFmPresetProvider);
    final frequency = ref.watch(archFmFrequencyProvider);
    final staticLabel = ref.watch(archFmStaticProvider.notifier).label;
    final duo = ref.watch(archFmDuoProvider);
    final now = DateTime.now();
    final part = daypartForHour(now.hour);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  CupertinoIcons.dot_radiowaves_left_right,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      enabled ? 'On air' : 'Off air',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      enabled
                          ? '${voice.label} on the mic, ${_partLabel(part)} pack'
                          : 'Off, music plays straight through',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              ArchSwitch(
                value: enabled,
                onChanged: (_) =>
                    ref.read(archFmEnabledProvider.notifier).toggle(),
              ),
            ],
          ),
        ),
        SettingGroup(
          title: 'Host',
          children: [
            for (final v in KokoroVoice.values)
              SettingRow(
                icon: v == KokoroVoice.bella
                    ? CupertinoIcons.person_fill
                    : CupertinoIcons.person_crop_circle_fill,
                title: v.label,
                subtitle: v.persona,
                trailing: v == voice
                    ? Icon(
                        CupertinoIcons.check_mark_circled_solid,
                        color: scheme.primary,
                      )
                    : null,
                onTap: () =>
                    ref.read(archFmVoiceProvider.notifier).setVoice(v),
              ),
          ],
        ),
        SettingGroup(
          title: 'Sound',
          children: [
            SettingRow(
              icon: CupertinoIcons.slider_horizontal_3,
              title: 'Preset',
              subtitle: '${preset.label}, ${preset.blurb}',
              trailing: Text(
                'Change',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () {
                final next = FmPreset.values[(FmPreset.values.indexOf(preset) +
                        1) %
                    FmPreset.values.length];
                ref.read(archFmPresetProvider.notifier).setPreset(next);
              },
            ),
            SettingRow(
              icon: CupertinoIcons.waveform,
              title: 'Static bed',
              subtitle: '$staticLabel crackle under the voice',
              trailing: Text(
                'Change',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () =>
                  ref.read(archFmStaticProvider.notifier).cycle(),
            ),
            SettingRow(
              icon: CupertinoIcons.repeat,
              title: 'Break every',
              subtitle: 'Every $frequency songs',
              trailing: Text(
                'Change',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () =>
                  ref.read(archFmFrequencyProvider.notifier).cycle(),
            ),
          ],
        ),
        SettingGroup(
          title: 'Voices',
          children: [
            SettingRow(
              icon: CupertinoIcons.person_2_fill,
              title: 'Duo handoffs',
              subtitle: duo
                  ? 'On, Bella and Michael trade breaks'
                  : 'Off, duo handoffs arrive later',
              trailing: ArchSwitch(
                value: duo,
                onChanged: (_) =>
                    ref.read(archFmDuoProvider.notifier).toggle(),
              ),
              onTap: () =>
                  ref.read(archFmDuoProvider.notifier).toggle(),
            ),
            SettingRow(
              icon: CupertinoIcons.play_fill,
              title: 'Test voice',
              subtitle: 'Render one liner with ${voice.label}',
              onTap: () => _testVoice(context, ref),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            'Full stop breaks between songs, masked with static '
            'so the edits sound seamless. Missed render means a '
            'skipped break, never stalled music.',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  String _partLabel(Daypart part) => switch (part) {
    Daypart.morning => 'morning',
    Daypart.daytime => 'daytime',
    Daypart.evening => 'evening',
    Daypart.lateNight => 'late night',
  };

  Future<void> _testVoice(BuildContext context, WidgetRef ref) async {
    final voice = ref.read(archFmVoiceProvider);
    final preset = ref.read(archFmPresetProvider);
    final engine = ref.read(kokoroEngineProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (engine.status != EngineStatus.ready) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Voice engine not installed, get it in Settings, Playback'),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Rendering one liner with ${voice.label}')),
    );
    final service = ArchFmService();
    final pick = service.nextBreak(now: DateTime.now());
    await service.playSample(
      text: pick.text,
      voice: voice,
      preset: preset,
    );
    ArchLog.i('archfm', 'test voice played: ${pick.liner.id}');
  }
}
