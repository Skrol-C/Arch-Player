import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_prefs.dart';
import '../../../core/log.dart';
import '../../../core/theme.dart';
import '../widgets/setting_bits.dart';

/// Appearance: theme choice with a live preview card. The preview
/// renders the candidate theme inline — what you see is what the
/// whole app becomes on tap. Persisted, hot-swaps instantly.
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'appearance open');
    final mode = ref.watch(appThemeModeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Theme',
            children: [
              for (final m in AppThemeMode.values)
                _ThemeRow(mode: m, selected: m == mode),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Preview',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          _PreviewCard(mode: mode),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              mode == AppThemeMode.amoled
                  ? 'AMOLED paints true black so OLED pixels stay off. '
                        'Borders and text separate by tone — no glow, no haze.'
                  : mode == AppThemeMode.dark
                  ? 'Dark keeps the soft raised surfaces for dim rooms.'
                  : mode == AppThemeMode.light
                  ? 'Light is the classic Arch white day-mode.'
                  : 'Follows the system setting.',
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

class _ThemeRow extends ConsumerWidget {
  final AppThemeMode mode;
  final bool selected;

  const _ThemeRow({required this.mode, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: switch (mode) {
            AppThemeMode.light => paperRaised,
            AppThemeMode.amoled => amoledBlack,
            AppThemeMode.dark => night,
            AppThemeMode.system => scheme.surfaceContainerHighest,
          },
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: scheme.outline.withValues(alpha: 0.4),
          ),
        ),
        child: Icon(
          switch (mode) {
            AppThemeMode.light => Icons.light_mode_rounded,
            AppThemeMode.dark => Icons.dark_mode_rounded,
            AppThemeMode.amoled => Icons.contrast_rounded,
            AppThemeMode.system => Icons.settings_suggest_rounded,
          },
          color: selected ? archPink : scheme.onSurfaceVariant,
        ),
      ),
      title: Text(
        switch (mode) {
          AppThemeMode.system => 'System',
          AppThemeMode.light => 'Light',
          AppThemeMode.dark => 'Dark',
          AppThemeMode.amoled => 'AMOLED',
        },
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        switch (mode) {
          AppThemeMode.system => 'Follow the phone',
          AppThemeMode.light => 'Classic Arch white',
          AppThemeMode.dark => 'Soft raised dark',
          AppThemeMode.amoled => 'True black, OLED saver',
        },
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
      trailing: selected
          ? const Icon(Icons.check_circle_rounded, color: archPink)
          : null,
      onTap: () => ref.read(appThemeModeProvider.notifier).set(mode),
    );
  }
}

/// Live preview: a miniature song row + switch rendered under the
/// candidate theme, so the choice is visual, not a name.
class _PreviewCard extends StatelessWidget {
  final AppThemeMode mode;

  const _PreviewCard({required this.mode});

  @override
  Widget build(BuildContext context) {
    final preview = switch (mode) {
      AppThemeMode.light => archTheme(),
      AppThemeMode.dark => archDarkTheme(),
      AppThemeMode.amoled => archDarkTheme(amoled: true),
      AppThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark
            ? archDarkTheme()
            : archTheme(),
    };
    return Theme(
      data: preview,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [archPink, archPinkDim],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.music_note_rounded,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Midnight Static',
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Neon Coastline',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.play_circle_fill_rounded,
                        color: archPink,
                        size: 32,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Background playback',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 14,
                        ),
                      ),
                      Container(
                        width: 44,
                        height: 26,
                        decoration: BoxDecoration(
                          color: archPink,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 3),
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
