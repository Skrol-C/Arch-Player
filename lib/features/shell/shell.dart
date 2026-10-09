import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/log.dart';
import '../../core/theme.dart';

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
            Destination.needle => const _NeedleTeaser(key: ValueKey('dest-needle')),
            Destination.settings => const _DemoList(key: ValueKey('dest-settings'), title: 'Settings'),
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

/// Needle teaser: name, promise, no dead end. Engine lands per vision §8.
class _NeedleTeaser extends StatelessWidget {
  const _NeedleTeaser({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 96, 24, 160),
      children: [
        Text('Needle', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'Music, gotten inside the app. Providers plug in here — no second app needed.',
          style: TextStyle(color: inkDim, height: 1.5),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: paperRaised,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Coming soon', style: TextStyle(color: archPink, fontWeight: FontWeight.w700)),
              SizedBox(height: 8),
              Text(
                'Search, queue, and keep downloads with tags intact. '
                'Sources arrive as community providers.',
                style: TextStyle(color: inkDim, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
