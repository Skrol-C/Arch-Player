import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../library/library_providers.dart';
import '../settings/settings_screen.dart';
import '../shell/dock.dart';
import 'profile_pic.dart';

/// Profile: your library at a glance. Settings lives here now —
/// the pill stays four destinations.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songsAsync = ref.watch(songsProvider);
    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        backgroundColor: paper,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 4,
        title: LiquidGlassLens(
          style: ArchGlass.circle(radius: 24),
          child: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon:
                const Icon(CupertinoIcons.chevron_left, color: ink),
          ),
        ),
      ),
      body: Stack(
        children: [
          DockScrollReporter(
            child: CustomScrollView(
              physics: const ClampingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _head(context, ref)),
                const SliverToBoxAdapter(child: SizedBox(height: 20)),
                songsAsync.when(
                  loading: () => const SliverToBoxAdapter(
                    child: Center(
                      child: CircularProgressIndicator(
                          color: archPink, strokeWidth: 2),
                    ),
                  ),
                  error: (_, _) => const SliverToBoxAdapter(
                    child: SizedBox.shrink(),
                  ),
                  data: (songs) =>
                      SliverToBoxAdapter(child: _stats(context, ref, songs)),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 20)),
                SliverToBoxAdapter(child: _rows(context, ref)),
                const SliverToBoxAdapter(child: SizedBox(height: 140)),
              ],
            ),
          ),
          const NowPlayingDock(),
        ],
      ),
    );
  }

  Widget _head(BuildContext context, WidgetRef ref) {
    final pic = ref.watch(profilePicProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          GestureDetector(
            onTap: () =>
                ref.read(profilePicProvider.notifier).pick(),
            child: Stack(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: paperRaised,
                    borderRadius: BorderRadius.circular(36),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: pic != null
                      ? Image.file(
                          File(pic),
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            CupertinoIcons.person_fill,
                            color: inkDim,
                            size: 34,
                          ),
                        )
                      : const Icon(
                          CupertinoIcons.person_fill,
                          color: inkDim,
                          size: 34,
                        ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: archPink,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      CupertinoIcons.pencil,
                      color: Colors.white,
                      size: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Library',
                  style: TextStyle(
                    fontFamily: 'ArchSerif',
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  'Taste, stats, settings',
                  style: TextStyle(color: inkDim, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stats(BuildContext context, WidgetRef ref, List<Song> songs) {
    final artists = {
      for (final s in songs)
        if (s.artist.trim().isNotEmpty &&
            !isUnknownSlot(s.artist))
          s.artist.trim().toLowerCase(): s.artist.trim(),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _stat('${songs.length}', 'Songs'),
            _stat('${artists.length}', 'Artists'),
            _stat(
                '${songs.where((s) => s.albumId > 0).map((s) => s.albumId).toSet().length}',
                'Albums'),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: inkDim, fontSize: 12),
        ),
      ],
    );
  }

  Widget _rows(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          _row(
            context,
            icon: CupertinoIcons.settings,
            title: 'Settings',
            subtitle: 'Extensions, downloads, playback',
            onTap: () {
              HapticFeedback.selectionClick();
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(icon, color: ink, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    subtitle,
                    style:
                        const TextStyle(color: inkDim, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(CupertinoIcons.chevron_right,
                color: inkDim, size: 18),
          ],
        ),
      ),
    );
  }
}
