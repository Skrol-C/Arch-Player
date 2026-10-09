import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import '../settings/needle_teaser.dart';
import '../settings/settings_screen.dart';

enum Destination { library, needle, settings }

final destinationProvider = StateProvider<Destination>((ref) => Destination.library);

const _labels = ['Library', 'Needle', 'Settings'];
const _icons = [Icons.library_music_rounded, Icons.download_rounded, Icons.settings_rounded];

/// Phase-0 shell: white backdrop with demo content for the lens to bend,
/// traveling glass pill, three destinations (Needle = designed teaser).
class Shell extends ConsumerWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dest = ref.watch(destinationProvider);
    ArchLog.i('nav', 'shell build dest=$dest');
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          switch (dest) {
            Destination.library => const _DemoList(key: ValueKey('dest-library'), title: 'Library'),
            Destination.needle => const NeedleTeaser(key: ValueKey('dest-needle')),
            Destination.settings => const SettingsScreen(key: ValueKey('dest-settings')),
          },
          LiquidGlassTabBar.withImpeller(
            items: [
              for (var i = 0; i < _labels.length; i++)
                LiquidGlassTabBarItem(icon: _icons[i], label: _labels[i]),
            ],
            selectedIndex: dest.index,
            onChanged: (i) {
              ArchLog.i('nav', 'pill -> ${Destination.values[i]}');
              ref.read(destinationProvider.notifier).state = Destination.values[i];
            },
            width: 340,
            margin: const EdgeInsets.only(bottom: 40),
            itemStyle: const LiquidGlassTabItemStyle(
              selectedColor: archPink,
              unselectedColor: Color(0x990B0B0D),
              iconSize: 24,
              underGlassIconSize: 30,
              labelFontSize: 11,
            ),
            pillStyle: const LiquidGlassTabPillStyle(animated: true),
            style: LiquidGlassTabBar.defaultStyle.copyWith(
              appearance: const LiquidGlassAppearance(color: Color(0x14000000)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stand-in content: rows for the lens to bend. Replaced by real slices.
/// (Needle teaser lives in settings/ until the engine lands.)
class _DemoList extends StatelessWidget {
  final String title;
  const _DemoList({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 72, 20, 160),
      itemCount: 24,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  colors: [
                    Color.lerp(archPink, const Color(0xFFFF9E9E), i / 24)!,
                    paperRaised,
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 15, width: 150.0 + (i % 5) * 24, color: ink.withValues(alpha: 0.75)),
                  const SizedBox(height: 6),
                  Container(height: 12, width: 96.0 + (i % 3) * 20, color: inkDim.withValues(alpha: 0.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
