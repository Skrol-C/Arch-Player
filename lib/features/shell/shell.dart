import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/theme.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../player/player_providers.dart';
import '../player/player_screen.dart';
import '../settings/settings_screen.dart';

enum Destination { home, library, settings }

final destinationProvider = StateProvider<Destination>((ref) => Destination.library);

const _labels = ['Home', 'Library', 'Settings'];
const _icons = [Icons.home_rounded, Icons.library_music_rounded, Icons.settings_rounded];

/// App shell: destination content + traveling liquid-glass pill nav.
class Shell extends ConsumerWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dest = ref.watch(destinationProvider);
    final playerOpen = ref.watch(playerOpenProvider);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          switch (dest) {
            Destination.home => const HomeScreen(),
            Destination.library => const LibraryScreen(),
            Destination.settings => const SettingsScreen(),
          },
          if (!playerOpen)
            LiquidGlassTabBar.withImpeller(
              items: [
                for (var i = 0; i < _labels.length; i++)
                  LiquidGlassTabBarItem(icon: _icons[i], label: _labels[i]),
              ],
              selectedIndex: dest.index,
              onChanged: (i) => ref.read(destinationProvider.notifier).state =
                  Destination.values[i],
              width: 340,
              margin: const EdgeInsets.only(bottom: 40),
              itemStyle: const LiquidGlassTabItemStyle(
                selectedColor: archRed,
                unselectedColor: Color(0xD9FFFFFF),
                iconSize: 24,
                underGlassIconSize: 30,
                labelFontSize: 11,
              ),
              pillStyle: const LiquidGlassTabPillStyle(animated: true),
              style: LiquidGlassTabBar.defaultStyle.copyWith(
                appearance: const LiquidGlassAppearance(color: Color(0x14FFFFFF)),
              ),
            ),
          if (playerOpen) const PlayerScreen(),
        ],
      ),
    );
  }
}
