import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../search/provider_marks.dart';
import 'extension.dart';
import 'needle_store.dart';
import 'packages.dart';
import 'queue_runner.dart';
import 'queue_store.dart';

/// Download sheet (SpotiFLAC grammar, our skin): track header
/// with art, provider chips, then that provider's OWN quality
/// options (manifest `qualityOptions`; 3-tier fallback only when
/// the manifest declares none). Tapping a quality row fires
/// immediately - no separate Download button. One glass lens
/// (the sheet); option pills are white frost, never nested
/// lenses, so text stays readable and the Honor stays cool.
/// Returns true when a pull was enqueued.
Future<bool> showDownloadSheet(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String artist,
  String album = '',
  String art = '',
  String isrc = '',
  String providerId = '',
  String releaseType = '',
}) async {
  final downloaders = [
    for (final p in ref.read(installedExtensionsProvider))
      if (p.enabled && p.roles.contains('download')) p,
  ]..sort((a, b) => a.priority.compareTo(b.priority));
  if (downloaders.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No download provider enabled')),
      );
    }
    return false;
  }
  InstalledExtension selected = downloaders.first;
  for (final p in downloaders) {
    if (p.id == providerId) {
      selected = p;
      break;
    }
  }
  String quality = ref.read(downloadQualityProvider);
  final picked = await showModalBottomSheet<(String, String)?>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.88,
    ),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LiquidGlassLens(
        style: ArchGlass.sheet(radius: 28),
        child: _Sheet(
          title: title,
          artist: artist,
          art: art,
          downloaders: downloaders,
          initialProvider: selected,
          initialQuality: quality,
          onPick: (p, q) {
            selected = p;
            quality = q;
          },
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return false;
  HapticFeedback.mediumImpact();
  final queue = ref.read(downloadQueueProvider.notifier);
  queue.enqueue(
    title: title,
    artist: artist,
    album: album,
    art: art,
    isrc: isrc,
    providers: downloaders,
    providerId: picked.$1,
    quality: picked.$2,
    releaseType: releaseType,
  );
  runQueue(ProviderScope.containerOf(context, listen: false));
  ArchLog.i(
      'queue', 'enqueued $title via ${picked.$1} @ ${picked.$2}');
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Queued — watch it in Needle')),
    );
  }
  return true;
}

/// One manifest quality option, normalized. Falls back to the
/// house tiers when the manifest declares none.
class _Quality {
  final String id;
  final String label;
  final String description;
  const _Quality(this.id, this.label, this.description);
}

Future<List<_Quality>> _qualitiesFor(String extId) async {
  try {
    final m = await readInstalledManifest(extId);
    if (m != null && m.qualityOptions.isNotEmpty) {
      return [
        for (final q in m.qualityOptions)
          _Quality(q.id, q.label, q.description),
      ];
    }
  } catch (_) {}
  return [
    for (final e in NeedlePrefs.qualities.entries)
      _Quality(e.key, e.value, _tierDetail(e.key)),
  ];
}

String _tierDetail(String id) => switch (id) {
      NeedlePrefs.qualityLossless => 'FLAC · 44.1kHz 16-bit',
      NeedlePrefs.qualityHigh => 'MP3 · 320kbps',
      NeedlePrefs.qualityNormal => 'MP3 · 128kbps',
      _ => '',
    };

/// Sourced codec mark for a quality id: logo file by format
/// keyword, geometric fallback otherwise (shared FormatChip
/// grammar, white-tile variant for dark rows).
String? _codecAsset(String id) {
  final s = id.toLowerCase();
  if (s.contains('atmos')) return 'assets/logos/dolby/dolby-atmos.png';
  if (s.contains('dolby') || s.contains('ac-4') || s.contains('ac4')) {
    return 'assets/logos/dolby/dolby-digital-plus.png';
  }
  if (s.contains('flac') || s.contains('lossless') || s.contains('hi_res')) {
    return 'assets/logos/flac/flac.png';
  }
  if (s.contains('mp3')) return 'assets/logos/mp3.png';
  if (s.contains('aac') || s.contains('m4a')) {
    return 'assets/logos/m4a/m4a.png';
  }
  if (s.contains('opus')) return 'assets/logos/opus/opus.png';
  if (s.contains('ogg') || s.contains('vorbis')) {
    return 'assets/logos/ogg/vorbis.png';
  }
  return null;
}

class _Sheet extends StatefulWidget {
  final String title;
  final String artist;
  final String art;
  final List<InstalledExtension> downloaders;
  final InstalledExtension initialProvider;
  final String initialQuality;
  final void Function(InstalledExtension, String) onPick;
  const _Sheet({
    required this.title,
    required this.artist,
    required this.art,
    required this.downloaders,
    required this.initialProvider,
    required this.initialQuality,
    required this.onPick,
  });

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  late InstalledExtension _provider;
  List<_Quality> _qualities = const [];
  bool _loadingQualities = true;

  @override
  void initState() {
    super.initState();
    _provider = widget.initialProvider;
    _load();
  }

  Future<void> _load() async {
    final qs = await _qualitiesFor(_provider.id);
    if (!mounted) return;
    setState(() {
      _qualities = qs;
      _loadingQualities = false;
    });
  }

  Future<void> _selectProvider(InstalledExtension p) async {
    if (p.id == _provider.id) return;
    HapticFeedback.selectionClick();
    setState(() {
      _provider = p;
      _qualities = const [];
      _loadingQualities = true;
    });
    final qs = await _qualitiesFor(p.id);
    if (!mounted) return;
    setState(() {
      _qualities = qs;
      _loadingQualities = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: widget.art.isEmpty
                      ? Container(
                          width: 56,
                          height: 56,
                          color: paperRaised,
                          child: const Icon(Icons.music_note_rounded,
                              color: inkDim),
                        )
                      : CachedNetworkImage(
                          imageUrl: widget.art,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => Container(
                            width: 56,
                            height: 56,
                            color: paperRaised,
                            child: const Icon(
                                Icons.music_note_rounded,
                                color: inkDim),
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 17),
                      ),
                      Text(
                        widget.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: inkDim, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Download from',
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in widget.downloaders)
                  _ProviderPill(
                    id: p.id,
                    displayName: p.displayName,
                    selected: p.id == _provider.id,
                    onTap: () => _selectProvider(p),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Select quality',
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 8),
            if (_loadingQualities)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        color: archPink, strokeWidth: 2),
                  ),
                ),
              )
            else
              for (var i = 0; i < _qualities.length; i++)
                _QualityRow(
                  quality: _qualities[i],
                  showDivider: i > 0,
                  onTap: () {
                    widget.onPick(_provider, _qualities[i].id);
                    Navigator.of(context)
                        .pop((_provider.id, _qualities[i].id));
                  },
                ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Clear provider pill: transparent with a hairline, pink when
/// selected. No frost fill — the sheet lens is the only glass.
class _ProviderPill extends StatelessWidget {
  final String id;
  final String displayName;
  final bool selected;
  final VoidCallback onTap;
  const _ProviderPill({
    required this.id,
    required this.displayName,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final asset = providerMarkAsset(id, displayName);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: Motion.stateChange,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? archPink : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : ink.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (asset != null) ...[
              SizedBox(
                width: 22,
                height: 22,
                child: SvgPicture.asset(asset),
              ),
              const SizedBox(width: 8),
            ] else ...[
              Text(
                displayName.isEmpty
                    ? '?'
                    : displayName.substring(0, 1).toUpperCase(),
                style: TextStyle(
                  color: selected ? Colors.white : ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              displayName,
              style: TextStyle(
                color: selected ? Colors.white : ink,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Borderless quality row: bare codec mark, label + description
/// in ink, chevron. Dividers separate rows (SpotiFLAC mornye
/// grammar). Tap fires immediately.
class _QualityRow extends StatelessWidget {
  final _Quality quality;
  final bool showDivider;
  final VoidCallback onTap;
  const _QualityRow(
      {required this.quality, required this.showDivider, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final asset = _codecAsset(quality.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDivider)
          const Divider(
            height: 0.5,
            indent: 62,
            endIndent: 16,
            color: Color(0x140B0B0D),
          ),
        GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: asset != null
                      ? Image.asset(asset,
                          width: 30,
                          height: 30,
                          errorBuilder: (_, _, _) => const Icon(
                              Icons.music_note_outlined,
                              color: inkDim,
                              size: 22))
                      : const Icon(Icons.music_note_outlined,
                          color: inkDim, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        quality.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: ink,
                        ),
                      ),
                      if (quality.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          quality.description,
                          style: const TextStyle(
                              color: inkDim, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.chevron_right_rounded,
                    size: 18, color: inkDim),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
