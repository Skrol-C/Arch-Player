import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_prefs.dart';
import '../../../core/log.dart';
import '../../../core/theme.dart';
import '../../player/player_providers.dart';
import '../widgets/arch_switch.dart';
import '../widgets/setting_bits.dart';

/// Appearance: pick a theme by tapping its phone. Each phone is a
/// stylized home screen rendered under that theme, so what you tap
/// is what the whole app becomes. Persisted, hot-swaps instantly.
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'appearance open');
    final mode = ref.watch(appThemeModeProvider);
    final goo = ref.watch(pillGooProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Text(
            'THEME',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            // Cell holds the phone plus its label below; the label
            // is what overflowed by ~26px at 0.62.
            childAspectRatio: 0.55,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final m in AppThemeMode.values)
                _PhoneOption(mode: m, selected: m == mode),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              switch (mode) {
                AppThemeMode.amoled =>
                  'AMOLED paints true black so OLED pixels stay off. '
                      'Cards sit on raised tiers with hairline strokes.',
                AppThemeMode.dark =>
                  'Dark keeps the soft raised surfaces for dim rooms.',
                AppThemeMode.light => 'Light is the classic Arch white.',
                AppThemeMode.system => 'Follows the system setting.',
              },
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          SettingGroup(
            title: 'Motion',
            children: [
              SettingRow(
                icon: Icons.water_drop_rounded,
                title: 'Melted pill',
                subtitle: goo
                    ? 'On, mini melts into the pill'
                    : 'Off, classic fall, lighter on GPU',
                trailing: ArchSwitch(
                  value: goo,
                  // Persisted inside the notifier itself.
                  onChanged: (v) {
                    ref.read(pillGooProvider.notifier).set(v);
                    ArchLog.i('settings', 'pill goo -> $v');
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One tappable phone: the theme name plus a miniature home screen
/// rendered under the candidate theme. The preview is the button.
class _PhoneOption extends ConsumerWidget {
  final AppThemeMode mode;
  final bool selected;

  const _PhoneOption({required this.mode, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = switch (mode) {
      AppThemeMode.light => archTheme(),
      AppThemeMode.dark => archDarkTheme(),
      AppThemeMode.amoled => archDarkTheme(amoled: true),
      AppThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark
            ? archDarkTheme()
            : archTheme(),
    };
    final label = switch (mode) {
      AppThemeMode.system => 'System',
      AppThemeMode.light => 'Light',
      AppThemeMode.dark => 'Dark',
      AppThemeMode.amoled => 'AMOLED',
    };
    return GestureDetector(
      onTap: () => ref.read(appThemeModeProvider.notifier).set(mode),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: selected
                      ? archPink
                      : Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.4),
                  width: selected ? 2.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Theme(data: preview, child: const _MiniHome()),
                  if (selected)
                    const Positioned(
                      right: 8,
                      top: 8,
                      child: Icon(
                        Icons.check_circle_rounded,
                        color: archPink,
                        size: 24,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? archPink
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stylized home screen, theme-agnostic: greeting, a search field,
/// three art tiles, a mini player row, and the pill. Reads every
/// color from the ambient scheme so each phone shows its own theme.
class _MiniHome extends StatelessWidget {
  const _MiniHome();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Good evening',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 26,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(13),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Expanded(
                    child: Container(
                      height: 58,
                      margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            archPink.withValues(alpha: 0.85 - i * 0.2),
                            archPinkDim.withValues(alpha: 0.9 - i * 0.15),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 38,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.35),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: archPink.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 7,
                          decoration: BoxDecoration(
                            color: scheme.onSurface,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: 6,
                          width: 54,
                          decoration: BoxDecoration(
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.play_arrow_rounded,
                    color: archPink,
                    size: 20,
                  ),
                ],
              ),
            ),
            const Spacer(),
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  const Icon(
                    Icons.home_rounded,
                    color: archPink,
                    size: 17,
                  ),
                  Icon(
                    Icons.library_music_rounded,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                    size: 17,
                  ),
                  Icon(
                    Icons.search_rounded,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                    size: 17,
                  ),
                  Icon(
                    Icons.download_rounded,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                    size: 17,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
