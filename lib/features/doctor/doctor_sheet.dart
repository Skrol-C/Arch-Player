import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/data/art_previews.dart';
import '../library/data/embedded_art.dart';
import '../library/data/media_writes.dart';
import '../library/data/tag_fields.dart';
import '../library/library_providers.dart';
import '../library/data/library_repository.dart';
import '../library/song_row.dart';
import '../lyrics/tag_lyrics.dart';
import '../lyrics/word_lyrics.dart';
import '../metadata/cover_measure.dart';
import '../metadata/lyrics_providers.dart';
import '../metadata/metadata_providers.dart';
import '../needle/bridge/api.dart' as bridge;
import '../needle/embed.dart';
import '../needle/enrich.dart';
import '../player/morph_icon.dart';
import '../song/song_page.dart';

/// Song Doctor + Lyric Finder, one glass sheet, two swipeable pages.
/// Opened from the song page `...` menu (Doctor on page 0, Finder on
/// page 1). House sheet grammar: one lens, drag handle, pills are
/// white frost, never nested lenses.
Future<void> showDoctorSheet(
  BuildContext context,
  SongRef songRef, {
  int initialPage = 0,
}) {
  return showModalBottomSheet<void>(
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
        child: _DoctorSheet(songRef: songRef, initialPage: initialPage),
      ),
    ),
  );
}

class _DoctorSheet extends StatefulWidget {
  final SongRef songRef;
  final int initialPage;
  const _DoctorSheet({required this.songRef, required this.initialPage});

  @override
  State<_DoctorSheet> createState() => _DoctorSheetState();
}

class _DoctorSheetState extends State<_DoctorSheet> {
  late final PageController _pages;
  late int _page;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage.clamp(0, 1);
    _pages = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
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
          Flexible(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.68,
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _DoctorPage(songRef: widget.songRef),
                  _FinderPage(songRef: widget.songRef),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 2; i++)
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _page == i
                        ? archPink
                        : inkDim.withValues(alpha: 0.3),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// Metadata fields the Doctor can fill from provider lanes. Anything
/// else (encoder, compilation, release type, totals) is display-only:
/// totals ride along with their number, the rest no lane supplies.
const _fillable = <String>{
  kTitle,
  kArtist,
  kAlbumArtist,
  kAlbum,
  kTrack,
  kDisc,
  kDate,
  kGenre,
  kComposer,
  kIsrc,
  kLabel,
  kCatalogNumber,
  kBarcode,
  kCopyright,
  kBpm,
};

/// Page 1: what the file carries, toggles for what's missing, fill
/// with preview-then-apply. Files never change sight-unseen.
class _DoctorPage extends ConsumerStatefulWidget {
  final SongRef songRef;
  const _DoctorPage({required this.songRef});

  @override
  ConsumerState<_DoctorPage> createState() => _DoctorPageState();
}

class _DoctorPageState extends ConsumerState<_DoctorPage> {
  final Set<String> _selected = {};
  PullMeta? _gathered;
  // Present-but-wrong identity fields (key -> canonical), computed at
  // gather time from the same meta the preview shows. Apply writes
  // these alongside the selected fills; Auto takes title/artist.
  Map<String, String> _corrections = {};
  bool _working = false;
  bool _applying = false;
  bool _autoWorking = false;
  String? _status;
  // Identity override from the filename/fingerprint step, when the
  // file itself names nothing.
  String? _idTitle;
  String? _idArtist;

  SongRef get _r => widget.songRef;
  Song? get _owned => _r.owned;

  /// Effective identity: the manual identification step wins (fresh
  /// user intent beats a stale tag), then file tags, then the library
  /// row. MediaStore `"<unknown>"` and any placeholder read as empty
  /// — they are holes, never a query.
  String _eff(String? tag, String row, String unknown, String? manual) {
    if (manual != null && manual.isNotEmpty && !isUnknownSlot(manual)) {
      return manual;
    }
    if (tag != null && tag.isNotEmpty && !isUnknownSlot(tag)) return tag;
    if (row.isNotEmpty && row != unknown && !isUnknownSlot(row)) return row;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final owned = _owned;
    if (owned == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: Text(
            'Song Doctor works on songs in your library. Swipe for the Lyric Finder.',
            textAlign: TextAlign.center,
            style: TextStyle(color: inkDim, fontSize: 14),
          ),
        ),
      );
    }
    final tagsAsync = ref.watch(tagFieldsProvider(owned.path));
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: 16),
          tagsAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child:
                    CircularProgressIndicator(color: archPink, strokeWidth: 2),
              ),
            ),
            error: (_, _) => const Text(
              'Could not read this file.',
              style: TextStyle(color: inkDim, fontSize: 14),
            ),
            data: (fields) => _body(context, owned, fields),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final r = _r;
    Widget art;
    if (r.artFile.isNotEmpty) {
      art = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.file(File(r.artFile),
            width: 100, height: 100, fit: BoxFit.cover),
      );
    } else if (r.owned != null && r.owned!.albumId > 0) {
      art = FileArtImage(
          path: r.owned!.path,
          albumId: r.owned!.albumId,
          size: 100,
          radius: 20);
    } else if (r.artUrl.isNotEmpty) {
      art = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: CachedNetworkImage(
          imageUrl: r.artUrl,
          width: 100,
          height: 100,
          memCacheWidth: 200,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _artFallback(),
        ),
      );
    } else {
      art = _artFallback();
    }
    final voice = artistVoiceOf(
        r.artist.isEmpty || r.artist == 'Unknown artist'
            ? r.title
            : r.artist);
    return Row(
      children: [
        art,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Song Doctor',
                style: TextStyle(
                  fontFamily: 'ArchSerif',
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                r.title.isEmpty ? 'Untitled' : r.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: voice,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: voiceSpacing(voice),
                ),
              ),
              Text(
                r.artist.isEmpty ? 'Unknown artist' : r.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: inkDim, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _artFallback() {
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Icon(CupertinoIcons.music_note, color: inkDim, size: 40),
    );
  }

  Widget _body(BuildContext context, Song song, TagFields fields) {
    final title = _eff(fields[kTitle], _r.title, 'Unknown title', _idTitle);
    final artist =
        _eff(fields[kArtist], _r.artist, 'Unknown artist', _idArtist);
    final album = fields[kAlbum] ?? _r.album;
    final needsId = title.isEmpty || artist.isEmpty;
    final missingKeys =
        _fillable.where((k) => _slot(fields, k) == null).toList();
    final presentKeys =
        tagFieldOrder.keys.where((k) => _slot(fields, k) != null).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (needsId) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: paperRaised,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This file names nothing.',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Identify it first — filename, then fingerprint.',
                  style: TextStyle(color: inkDim, fontSize: 13),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _working ? null : () => _identify(song),
                  child: const Text('Identify'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            _verdictChip(missingKeys.length),
            const Spacer(),
            if (missingKeys.isNotEmpty) ...[
              TextButton(
                onPressed: (_working || _applying || _autoWorking || needsId)
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _selected.addAll(missingKeys);
                          _gathered = null;
                          _corrections = {};
                        });
                      },
                child: const Text('Select all'),
              ),
              TextButton(
                onPressed: (_working || _applying || _autoWorking || needsId)
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _selected.clear();
                          _gathered = null;
                          _corrections = {};
                        });
                      },
                child: const Text('Clear'),
              ),
            ],
          ],
        ),
        if (missingKeys.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'Missing',
            style: TextStyle(
              fontFamily: 'ArchSerif',
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < missingKeys.length; i++)
            _missingRow(missingKeys[i], i),
          const SizedBox(height: 16),
        ],
        const Text(
          'In this file',
          style: TextStyle(
            fontFamily: 'ArchSerif',
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        if (presentKeys.isEmpty)
          const Text(
            'Nothing yet.',
            style: TextStyle(color: inkDim, fontSize: 14),
          )
        else
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: paperRaised,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                for (var i = 0; i < presentKeys.length; i++)
                  _presentRow(presentKeys[i], fields),
              ],
            ),
          ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (_working ||
                    _applying ||
                    _autoWorking ||
                    needsId)
                ? null
                : () => _auto(song, title, artist, album, fields),
            icon: const Icon(CupertinoIcons.sparkles, size: 16),
            label: Text(_autoWorking ? 'Auto-fixing…' : 'Auto'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: (_working ||
                    _applying ||
                    _autoWorking ||
                    needsId ||
                    _selected.isEmpty)
                ? null
                : () => _fill(song, title, artist, album, fields),
            child: Text(_working
                ? 'Asking providers…'
                : 'Fill ${_selected.length} field${_selected.length == 1 ? '' : 's'}'),
          ),
        ),
        if (_working || _autoWorking) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(color: archPink),
        ],
        if (_gathered != null) ...[
          const SizedBox(height: 16),
          _preview(song, fields),
        ],
        if (_status != null) ...[
          const SizedBox(height: 12),
          Text(_status!, style: const TextStyle(color: inkDim, fontSize: 13)),
        ],
      ],
    );
  }

  Widget _verdictChip(int missing) {
    final clean = missing == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: clean ? paperRaised : archPink.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        clean ? 'Complete' : '$missing missing',
        style: TextStyle(
          color: clean ? inkDim : archPink,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _missingRow(String key, int index) {
    final label = tagFieldOrder[key]!;
    return CascadeIn(
      delayMs: index.clamp(0, 8) * 30,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label, style: const TextStyle(fontSize: 14)),
        subtitle: Text('N/A',
            style:
                TextStyle(color: inkDim.withValues(alpha: 0.7), fontSize: 14)),
        value: _selected.contains(key),
        activeThumbColor: archPink,
        onChanged: (on) {
          HapticFeedback.selectionClick();
          setState(() {
            if (on) {
              _selected.add(key);
            } else {
              _selected.remove(key);
            }
            _gathered = null;
                          _corrections = {};
          });
        },
      ),
    );
  }

  Widget _presentRow(String key, TagFields fields) {
    final label = tagFieldOrder[key]!;
    final value = _display(fields, key)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child:
                Text(label, style: const TextStyle(color: inkDim, fontSize: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }

  String? _display(TagFields fields, String key) {
    if (key == kTrack) return fields.numbered(kTrack, kTrackTotal);
    if (key == kDisc) return fields.numbered(kDisc, kDiscTotal);
    return fields[key];
  }

  /// Slot value with placeholders read as holes: a literal `"<unknown>"`
  /// atom fossilized by an old echo-write is missing, not data. Drives
  /// the missing/present split; raw display stays verbatim.
  String? _slot(TagFields fields, String key) {
    final v = _display(fields, key);
    if (v == null || isUnknownSlot(v)) return null;
    return v;
  }

  /// "Artist - Title" out of a filename, minus track numbers and the
  /// extension. Returns (artist, title) or null when there is nothing
  /// shaped like a credit in it.
  (String, String)? _parseFilename(String path) {
    var base = path.split('/').last.split('\\').last;
    base = base.replaceAll(RegExp(r'\.[a-zA-Z0-9]{2,5}$'), '');
    base = base.replaceAll(RegExp(r'^\d{1,3}[.\s-]+'), '').trim();
    final parts = base.split(RegExp(r'\s+-\s+'));
    if (parts.length < 2) return null;
    final artist = parts.first.trim();
    final title = parts.sublist(1).join(' - ').trim();
    if (artist.isEmpty || title.isEmpty) return null;
    return (artist, title);
  }

  Future<void> _identify(Song song) async {
    setState(() {
      _working = true;
      _status = null;
    });
    // Lane 1: the filename usually carries "Artist - Title".
    final parsed = _parseFilename(song.path);
    if (parsed != null) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _idArtist = parsed.$1;
        _idTitle = parsed.$2;
      });
      HapticFeedback.mediumImpact();
      ArchLog.i('doctor', 'identify: "${parsed.$2}" by ${parsed.$1}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Identified as ${parsed.$2} — ${parsed.$1}')),
      );
      return;
    }
    // Lane 2: the audio itself. Fingerprint decodes in Rust, lookup
    // stays Dart; the song's own duration wins over the print's.
    if (mounted) {
      setState(() => _status = 'Listening to the audio itself…');
    }
    try {
      final raw = await bridge.needleFingerprint(path: song.path);
      final m = jsonDecode(raw) as Map;
      if (m['ok'] == true) {
        final dur = song.duration.inSeconds > 0
            ? song.duration.inSeconds
            : (m['duration'] as num?)?.toInt() ?? 0;
        final hit = await ref.read(metadataServiceProvider).acoustidLookup(
              fingerprint: (m['fingerprint'] as String?) ?? '',
              durationSecs: dur,
            );
        if (hit != null && mounted) {
          setState(() {
            _working = false;
            _idTitle = hit.$1;
            _idArtist = hit.$2;
            _status = null;
          });
          HapticFeedback.mediumImpact();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Identified as ${hit.$1} — ${hit.$2}')),
          );
          return;
        }
      }
    } catch (e) {
      ArchLog.w('doctor', 'fingerprint identify failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _status = 'Unrecognizable — the filename holds nothing and the audio matched nothing.';
    });
  }

  Future<void> _fill(Song song, String title, String artist, String album,
      TagFields fields) async {
    setState(() {
      _working = true;
      _status = null;
      _gathered = null;
                          _corrections = {};
    });
    try {
      final meta = await gatherPullMeta(
        title: title,
        artist: artist,
        album: album,
        isrc: fields[kIsrc] ?? '',
        durationSecs: song.duration.inSeconds,
        includeLyrics: false,
        includeCover: false,
        resolveIdentity: true,
      );
      if (!mounted) return;
      setState(() {
        _working = false;
        _gathered = meta;
        _corrections = _correctionsFor(fields, meta);
        _status = meta.identityConflict
            ? 'Multiple albums found — pick manually.'
            : null;
      });
      ArchLog.i('doctor', 'fill: gathered for $title - $artist'
          '${meta.identityResolved ? ' (identity -> ${meta.title} - ${meta.artist} [${meta.album}])' : ''}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _status = 'Providers said nothing useful.';
      });
      ArchLog.w('doctor', 'fill failed: $e');
    }
  }

  Widget _preview(Song song, TagFields fields) {
    final meta = _gathered!;
    final rows = <List<String>>[];
    for (final key in _selected) {
      // Conflict: either album could be wrong, so identity fields
      // propose nothing rather than a guess.
      if (meta.identityConflict &&
          (key == kTitle || key == kArtist || key == kAlbum)) {
        continue;
      }
      final proposal = _proposalFor(key, meta);
      if (proposal.isEmpty || isUnknownSlot(proposal)) continue;
      rows.add([tagFieldOrder[key]!, _display(fields, key) ?? 'N/A', proposal]);
    }
    // Title the file carries but the catalogues correct, e.g.
    // "Usimamane - Cheque" -> "Cheque". Shown with the fills, applied
    // by the same button.
    for (final e in _corrections.entries) {
      rows.add([tagFieldOrder[e.key]!, _display(fields, e.key) ?? 'N/A', e.value]);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Proposed',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            const Text(
              'Nothing found for the selected fields.',
              style: TextStyle(color: inkDim, fontSize: 14),
            )
          else
            for (final r in rows) ...[
              _previewRow(r[0], r[1], r[2]),
              const SizedBox(height: 6),
            ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: (_applying || rows.isEmpty)
                      ? null
                      : () => _apply(song, rows),
                  child: Text(_applying ? 'Writing…' : 'Apply'),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _applying
                    ? null
                    : () => setState(() {
                          _gathered = null;
                          _corrections = {};
                          _selected.clear();
                        }),
                child: const Text('Start over'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewRow(String label, String old, String next) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: inkDim, fontSize: 12)),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.only(left: 8),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: archPink, width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                old,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: inkDim.withValues(alpha: 0.8),
                  fontSize: 14,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
              Text(
                next,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Present-but-wrong identity fields: the file names something and
  /// the catalogues verify another. Only when identity resolved
  /// cleanly — a miss or conflict proposes nothing.
  Map<String, String> _correctionsFor(TagFields fields, PullMeta meta,
      {bool includeAlbum = true}) {
    if (!meta.identityResolved || meta.identityConflict) return const {};
    final out = <String, String>{};
    void consider(String key, String canon) {
      if (canon.trim().isEmpty || isUnknownSlot(canon)) return;
      final fileVal = _display(fields, key);
      // Missing is the fill path, not a correction.
      if (fileVal == null || isUnknownSlot(fileVal)) return;
      if (fileVal.trim().toLowerCase() != canon.trim().toLowerCase()) {
        out[key] = canon;
      }
    }

    consider(kTitle, meta.title);
    consider(kArtist, meta.artist);
    if (includeAlbum) consider(kAlbum, meta.album);
    return out;
  }

  String _proposalFor(String key, PullMeta meta) {
    switch (key) {
      case kTitle:
        return meta.title;
      case kArtist:
        return meta.artist;
      case kAlbum:
        return meta.album;
      case kAlbumArtist:
        return meta.albumArtist;
      case kTrack:
        return meta.trackNumber.isEmpty
            ? ''
            : (meta.trackTotal.isEmpty
                ? meta.trackNumber
                : '${meta.trackNumber} / ${meta.trackTotal}');
      case kDisc:
        return meta.discNumber.isEmpty
            ? ''
            : (meta.discTotal.isEmpty
                ? meta.discNumber
                : '${meta.discNumber} / ${meta.discTotal}');
      case kDate:
        return meta.date;
      case kGenre:
        return meta.genres.isEmpty ? '' : meta.genres.first;
      case kComposer:
        return meta.composer;
      case kIsrc:
        return meta.isrc;
      case kLabel:
        return meta.label;
      case kCatalogNumber:
        return meta.catalogNumber;
      case kBarcode:
        return meta.barcode;
      case kCopyright:
        return meta.copyright;
      case kBpm:
        return meta.bpm;
      default:
        return '';
    }
  }

  /// Sparse record: only [keys] ride along. tag() skips empties,
  /// lyrics stay out (Finder owns lyrics), and an empty coverUrl
  /// means the cover is left exactly as it is. Shared by manual
  /// Apply and Auto so the two can never disagree on what a write
  /// contains.
  PullMeta _sparseMeta(PullMeta meta, Set<String> keys,
      {String coverUrl = ''}) {
    return PullMeta(
      title: keys.contains(kTitle) ? meta.title : '',
      artist: keys.contains(kArtist) ? meta.artist : '',
      album: keys.contains(kAlbum) ? meta.album : '',
      genres: keys.contains(kGenre) && meta.genres.isNotEmpty
          ? [meta.genres.first]
          : const [],
      label: keys.contains(kLabel) ? meta.label : '',
      isrc: keys.contains(kIsrc) ? meta.isrc : '',
      composer: keys.contains(kComposer) ? meta.composer : '',
      albumArtist:
          keys.contains(kAlbumArtist) ? meta.albumArtist : '',
      trackNumber: keys.contains(kTrack) ? meta.trackNumber : '',
      trackTotal: keys.contains(kTrack) ? meta.trackTotal : '',
      discNumber: keys.contains(kDisc) ? meta.discNumber : '',
      discTotal: keys.contains(kDisc) ? meta.discTotal : '',
      date: keys.contains(kDate) ? meta.date : '',
      copyright: keys.contains(kCopyright) ? meta.copyright : '',
      bpm: keys.contains(kBpm) ? meta.bpm : '',
      catalogNumber:
          keys.contains(kCatalogNumber) ? meta.catalogNumber : '',
      barcode: keys.contains(kBarcode) ? meta.barcode : '',
      coverUrl: coverUrl,
    );
  }

  /// Longest embedded side below this reads as low quality. Matches
  /// the embed cap's intent: anything past it survives embedding
  /// intact, anything under it visibly doesn't.
  static const _lowQualitySide = 800;

  /// True when the file's own cover is missing or too small to
  /// survive a screen. Undecidable (unreadable bytes) reads as
  /// false: Auto never fetches on a guess.
  Future<bool> _coverNeedsWork(Song song) async {
    try {
      final art = await compute(readEmbeddedArt, song.path);
      if (art == null || art.bytes.isEmpty) return true;
      final codec = await ui.instantiateImageCodec(art.bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      final longSide = w > h ? w : h;
      return longSide < _lowQualitySide;
    } catch (_) {
      return false;
    }
  }

  /// Highest measured resolution wins, silent. Null when nothing
  /// measurable answered.
  Future<String?> _bestCoverUrl(
      List<({String label, String url, String thumb})> cands) async {
    final measured = await Future.wait([
      for (final c in cands) measureCoverArt(c.url),
    ]);
    String? bestUrlOut;
    var bestPixels = 0;
    for (var i = 0; i < cands.length; i++) {
      final m = measured[i];
      if (m == null) continue;
      final pixels = m.width * m.height;
      if (pixels > bestPixels) {
        bestPixels = pixels;
        bestUrlOut = cands[i].url;
      }
    }
    return bestPixels > 0 ? bestUrlOut : null;
  }

  /// Full auto, one tap: every missing field resolves to its
  /// strongest match (agreement first, lane priority after — the
  /// same mergedWith semantics as manual), the cover refreshes when
  /// missing or small, and ONE sparse record writes everything.
  /// Deliberate exception to preview-then-apply: the button promises
  /// speed, and the snackbar reports exactly what landed.
  Future<void> _auto(Song song, String title, String artist, String album,
      TagFields fields) async {
    // Captured before any await: reporting after async work must not
    // touch context across the gap.
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _autoWorking = true;
      _status = null;
      _gathered = null;
                          _corrections = {};
    });
    HapticFeedback.mediumImpact();
    String? tempIn;
    String? tagged;
    try {
      final missing =
          _fillable.where((k) => _slot(fields, k) == null).toList();
      final svc = ref.read(metadataServiceProvider);
      final metaFuture = gatherPullMeta(
        title: title,
        artist: artist,
        album: album,
        isrc: fields[kIsrc] ?? '',
        durationSecs: song.duration.inSeconds,
        includeLyrics: false,
        includeCover: false,
        resolveIdentity: true,
      );
      final coverNeededFuture = _coverNeedsWork(song);
      final meta = await metaFuture;
      final coverNeeded = await coverNeededFuture;
      if (!mounted) return;
      if (meta.identityConflict) {
        setState(() {
          _autoWorking = false;
          _status = 'Multiple albums found — the file was left alone.';
        });
        return;
      }
      final wins = <String, String>{};
      for (final key in missing) {
        if (meta.identityConflict &&
            (key == kTitle || key == kArtist || key == kAlbum)) {
          continue;
        }
        final v = _proposalFor(key, meta);
        // Placeholders are holes, never writes: nothing "<unknown>"
        // goes back into a file.
        if (v.isNotEmpty && !isUnknownSlot(v)) wins[key] = v;
      }
      // Present-but-wrong title/artist ride along: Auto promises the
      // fix, and the snackbar reports the count. Album stays
      // manual-only when present — it moves library grouping.
      wins.addAll(_correctionsFor(fields, meta, includeAlbum: false));
      String? coverUrl;
      if (coverNeeded) {
        // Resolved identity, not the raw file tags: the adopted
        // album is what tells the cover lane which release to fetch.
        final cands = await svc.coverCandidatesFor(
          artist: meta.artist.isNotEmpty ? meta.artist : artist,
          album: meta.album.isNotEmpty ? meta.album : album,
          title: meta.title.isNotEmpty ? meta.title : title,
        );
        if (mounted) coverUrl = await _bestCoverUrl(cands);
      }
      if (!mounted) return;
      if (wins.isEmpty && coverUrl == null) {
        setState(() {
          _autoWorking = false;
          _status = coverNeeded
              ? 'No better cover found.'
              : 'Everything already complete.';
        });
        return;
      }
      final sparse =
          _sparseMeta(meta, wins.keys.toSet(), coverUrl: coverUrl ?? '');
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final ext = song.path.split('.').last.toLowerCase();
      tempIn = '${dir.path}/doctor_$stamp.$ext';
      await File(song.path).copy(tempIn);
      tagged = await embedPullMeta(tempIn, sparse);
      if (tagged == tempIn) {
        throw StateError('nothing to write');
      }
      final outcome = await MediaWrites.retagWithConsent(
        uri: song.uri.toString(),
        srcPath: tagged,
        path: song.path,
      );
      ArchLog.i('doctor',
          'auto "${song.title}": ${outcome.name} (${wins.length} tags${coverUrl != null ? ' + cover' : ''})'
          '${meta.identityResolved ? ' identity->[${meta.album}]' : ''}');
      if (!mounted) return;
      switch (outcome) {
        case WriteOutcome.ok:
          await ArtPreviews.refresh(song.path);
          ArtCache.evictAlbum(song.albumId);
          ref.invalidate(songsProvider);
          ref.invalidate(tagFieldsProvider(song.path));
          setState(() {
            _autoWorking = false;
            _selected.clear();
            _status = null;
          });
          final filled = wins.length;
          messenger.showSnackBar(
            SnackBar(
              content: Text(filled > 0
                  ? 'Fixed $filled tag${filled == 1 ? '' : 's'}'
                      '${coverUrl != null ? ' + cover' : ''}.'
                  : 'Cover updated.'),
            ),
          );
        case WriteOutcome.denied:
          setState(() {
            _autoWorking = false;
            _status = 'Not permitted — the file was left alone.';
          });
        case WriteOutcome.failed:
          setState(() {
            _autoWorking = false;
            _status = 'Could not write ${song.path}.';
          });
      }
    } catch (e) {
      ArchLog.w('doctor', 'auto failed: $e');
      if (mounted) {
        setState(() {
          _autoWorking = false;
          _status = 'Auto-fix failed — the file was left alone.';
        });
      }
    } finally {
      for (final p in [tempIn, tagged]) {
        if (p == null) continue;
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _apply(Song song, List<List<String>> rows) async {
    setState(() {
      _applying = true;
      _status = null;
    });
    HapticFeedback.mediumImpact();
    final meta = _gathered!;
    final sparse =
        _sparseMeta(meta, {..._selected, ..._corrections.keys});
    String? tempIn;
    String? tagged;
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final ext = song.path.split('.').last.toLowerCase();
      tempIn = '${dir.path}/doctor_$stamp.$ext';
      await File(song.path).copy(tempIn);
      tagged = await embedPullMeta(tempIn, sparse);
      if (tagged == tempIn) {
        throw StateError('nothing to write');
      }
      final outcome = await MediaWrites.retagWithConsent(
        uri: song.uri.toString(),
        srcPath: tagged,
        path: song.path,
      );
      ArchLog.i('doctor', 'apply "${song.title}": ${outcome.name}');
      if (!mounted) return;
      switch (outcome) {
        case WriteOutcome.ok:
          ref.invalidate(songsProvider);
          ref.invalidate(tagFieldsProvider(song.path));
          setState(() {
            _applying = false;
            _gathered = null;
                          _corrections = {};
            _selected.clear();
            _status = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tags repaired.')),
          );
        case WriteOutcome.denied:
          setState(() {
            _applying = false;
            _status = 'Not permitted — the file was left alone.';
          });
        case WriteOutcome.failed:
          setState(() {
            _applying = false;
            _status = 'Could not write ${song.path}.';
          });
      }
    } catch (e) {
      ArchLog.w('doctor', 'apply failed: $e');
      if (mounted) {
        setState(() {
          _applying = false;
          _status = 'Repair failed — the file was left alone.';
        });
      }
    } finally {
      for (final p in [tempIn, tagged]) {
        if (p == null) continue;
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }
}

/// Page 2: what lyrics the song has now, and every better option the
/// providers hold. Word-level first, synced next, plain last resort —
/// each round polls every finder before the next begins, so a plain
/// result never shadows a synced one still in flight.
enum _LyricKind { words, synced, plain }

class _FinderPage extends ConsumerStatefulWidget {
  final SongRef songRef;
  const _FinderPage({required this.songRef});

  @override
  ConsumerState<_FinderPage> createState() => _FinderPageState();
}

class _FinderPageState extends ConsumerState<_FinderPage> {
  LyricDoc? _words;
  LyricDoc? _synced;
  LyricDoc? _plain;
  bool _doneWords = false;
  bool _doneSynced = false;
  bool _donePlain = false;
  _LyricKind _picked = _LyricKind.synced;
  bool _saving = false;
  String? _status;

  SongRef get _r => widget.songRef;

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
  }

  int get _dur =>
      _r.owned?.duration.inSeconds ?? (_r.durationMs ~/ 1000);

  Future<void> _poll() async {
    final svc = ref.read(metadataServiceProvider);
    final r = _r;
    // Rounds 1+2 share one LRCLib fetch: a single response carries
    // both syncedLines and lyricsfile words, so fetching twice
    // doubles traffic for the same bytes.
    LyricDoc lrc = const LyricDoc();
    try {
      lrc = await svc.lrclibDocFor(
        artist: r.artist,
        title: r.title,
        album: r.album,
        durationSecs: _dur,
      );
    } catch (_) {}
    if (!mounted) return;
    // Round 1: word timings.
    final words = lrc.hasWords ? lrc : const LyricDoc();
    setState(() {
      _words = words;
      _doneWords = true;
      if (words.hasWords) _picked = _LyricKind.words;
    });
    // Round 2: synced lines, every finder before plain is considered.
    LyricDoc? pax;
    if (!lrc.hasSynced) {
      try {
        pax = await svc.paxLyrics(
          artist: r.artist,
          title: r.title,
          durationSecs: _dur,
        );
      } catch (e) {
        ArchLog.w('finder', 'paxsenix lane failed: $e');
      }
    }
    if (!mounted) return;
    LyricDoc synced = const LyricDoc();
    if (lrc.hasSynced) {
      synced = lrc;
    } else if (pax != null && pax.hasSynced) {
      synced = pax;
    }
    setState(() {
      _synced = synced;
      _doneSynced = true;
      if (!(_words?.hasWords ?? false) && synced.hasSynced) {
        _picked = _LyricKind.synced;
      }
    });
    // Round 3: plain prose, last resort. Reuses the two docs above —
    // no second fetch — so plain can never overtake synced.
    LyricDoc plain = const LyricDoc();
    if (lrc.hasPlain) {
      plain = lrc;
    } else if (pax != null && pax.hasPlain) {
      plain = pax;
    }
    if (!mounted) return;
    setState(() {
      _plain = plain;
      _donePlain = true;
      if (!(_words?.hasWords ?? false) &&
          !(_synced?.hasSynced ?? false) &&
          plain.hasPlain) {
        _picked = _LyricKind.plain;
      }
    });
    ArchLog.i(
      'finder',
      'polled ${r.title} - ${r.artist}: '
      'words=${words.hasWords} synced=${synced.hasSynced} '
      'plain=${plain.hasPlain}',
    );
  }

  LyricDoc? _pickedDoc() => switch (_picked) {
        _LyricKind.words => _words,
        _LyricKind.synced => _synced,
        _LyricKind.plain => _plain,
      };

  bool _available(_LyricKind kind) {
    switch (kind) {
      case _LyricKind.words:
        return _doneWords && (_words?.hasWords ?? false);
      case _LyricKind.synced:
        return _doneSynced && (_synced?.hasSynced ?? false);
      case _LyricKind.plain:
        return _donePlain && (_plain?.hasPlain ?? false);
    }
  }

  bool _roundDone(_LyricKind kind) => switch (kind) {
        _LyricKind.words => _doneWords,
        _LyricKind.synced => _doneSynced,
        _LyricKind.plain => _donePlain,
      };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(CupertinoIcons.text_bubble, color: ink, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Lyric Finder',
                  style: TextStyle(
                    fontFamily: 'ArchSerif',
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _r.title.isEmpty ? 'Untitled' : _r.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 12),
          _currentCard(),
          const SizedBox(height: 16),
          const Text(
            'Pick a kind',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final kind in _LyricKind.values) ...[
                if (kind != _LyricKind.words) const SizedBox(width: 8),
                Expanded(child: _kindPill(kind)),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _previewCard(),
          const SizedBox(height: 16),
          if (_r.owned != null)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_saving || !_available(_picked))
                    ? null
                    : () => _use(_pickedDoc()!),
                child: Text(_saving ? 'Saving…' : 'Use these lyrics'),
              ),
            ),
          if (_saving) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(color: archPink),
          ],
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!,
                style: const TextStyle(color: inkDim, fontSize: 13)),
          ],
        ],
      ),
    );
  }

  Widget _currentCard() {
    final owned = _r.owned;
    if (owned == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Text(
          'Remote track — lyrics resolve when you play it.',
          style: TextStyle(color: inkDim, fontSize: 14),
        ),
      );
    }
    return FutureBuilder<LyricDoc>(
      future: compute(readEmbeddedLyrics, owned.path),
      builder: (context, snap) {
        String label;
        if (!snap.hasData) {
          label = 'Reading file…';
        } else {
          final doc = snap.data!;
          label = doc.hasSynced
              ? 'Embedded · ${_lineCount(doc.syncedLrc!)} lines synced'
              : doc.hasPlain
                  ? 'Embedded · plain text'
                  : 'No embedded lyrics';
        }
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: paperRaised,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Now',
                  style: TextStyle(color: inkDim, fontSize: 12)),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
            ],
          ),
        );
      },
    );
  }

  Widget _kindPill(_LyricKind kind) {
    final name = switch (kind) {
      _LyricKind.words => 'Word',
      _LyricKind.synced => 'Synced',
      _LyricKind.plain => 'Plain',
    };
    final done = _roundDone(kind);
    final ok = _available(kind);
    final selected = _picked == kind;
    return GestureDetector(
      onTap: (!done || !ok)
          ? null
          : () {
              HapticFeedback.selectionClick();
              setState(() => _picked = kind);
            },
      child: AnimatedContainer(
        duration: Motion.stateChange,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? archPink : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected
                ? archPink
                : ink.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          children: [
            Text(
              name,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? Colors.white : ink,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            if (done && !ok)
              Text(
                'not found',
                style: TextStyle(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.8)
                      : inkDim.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              )
            else if (!done)
              SizedBox(
                height: 14,
                width: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: selected ? Colors.white : inkDim,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _previewCard() {
    final doc = _pickedDoc();
    List<String> lines = const [];
    var note = '';
    if (doc != null) {
      if (doc.instrumental && !doc.hasSynced && !doc.hasPlain) {
        note = 'Instrumental — no words to show.';
      } else {
        lines = _previewLines(doc);
        if (_picked == _LyricKind.words && doc.hasWords) {
          final n = documentFromWordTimings(doc.wordTimings)?.lines.length;
          note = n == null
              ? 'Word timings found.'
              : 'Word timings found · $n lines.';
        }
      }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _sourceLabel(doc),
            style: const TextStyle(color: inkDim, fontSize: 12),
          ),
          const SizedBox(height: 6),
          if (note.isNotEmpty)
            Text(note,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          if (lines.isEmpty && note.isEmpty)
            const Text('Nothing here yet.',
                style: TextStyle(color: inkDim, fontSize: 14))
          else
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(l,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, height: 1.4)),
              ),
        ],
      ),
    );
  }

  List<String> _previewLines(LyricDoc doc) {
    final text = doc.syncedLrc ?? doc.plain ?? '';
    final out = <String>[];
    for (final raw in text.split('\n')) {
      final clean = raw.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
      if (clean.isEmpty) continue;
      out.add(clean);
      if (out.length >= 8) break;
    }
    return out;
  }

  String _sourceLabel(LyricDoc? doc) {
    if (doc == null) return 'Searching…';
    if (!doc.hasWords && !doc.hasSynced && !doc.hasPlain && !doc.instrumental) {
      return _roundDone(_picked) ? 'Not found' : 'Searching…';
    }
    return switch (doc.source) {
      LyricSource.embedded => 'Embedded lyrics',
      LyricSource.lrclib => 'LRCLib',
      LyricSource.paxsenix => 'External source',
      LyricSource.none => '',
    };
  }

  int _lineCount(String lrc) {
    var n = 0;
    for (final raw in lrc.split('\n')) {
      if (raw.trim().isNotEmpty) n++;
    }
    return n;
  }

  /// Save the pick so the player shows it. The cache entry is marked
  /// as an explicit pick, so the provider serves it before the file's
  /// own tags. LRCLib picks also embed into the file — the file is
  /// the durable home, the cache the fast path. PaxSenIX picks stay
  /// cache-only, per their terms.
  Future<void> _use(LyricDoc doc) async {
    final song = _r.owned;
    if (song == null) return;
    setState(() {
      _saving = true;
      _status = null;
    });
    HapticFeedback.mediumImpact();
    try {
      final svc = ref.read(metadataServiceProvider);
      await svc.saveLyrics(song.id, doc, picked: true);
      var embedded = false;
      if (doc.source == LyricSource.lrclib &&
          (doc.hasSynced || doc.hasPlain)) {
        embedded = await _retagLyrics(song, doc);
      }
      ref.invalidate(lyricsDocProvider(song.id));
      ArchLog.i('doctor',
          'finder: saved ${doc.source.name} lyrics for "${song.title}"${embedded ? ' (embedded too)' : ''}');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _status = embedded
            ? 'Saved — and written into the file.'
            : 'Saved — the player picks them up.';
      });
    } catch (e) {
      ArchLog.w('doctor', 'finder save failed: $e');
      if (mounted) {
        setState(() {
          _saving = false;
          _status = 'Could not save — nothing changed.';
        });
      }
    }
  }

  /// Lyrics-only retag: every tag field stays empty so the file's own
  /// metadata is untouched and only the lyric lines move. True when
  /// the bytes landed.
  Future<bool> _retagLyrics(Song song, LyricDoc doc) async {
    String? tempIn;
    String? tagged;
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final ext = song.path.split('.').last.toLowerCase();
      tempIn = '${dir.path}/finder_$stamp.$ext';
      await File(song.path).copy(tempIn);
      tagged = await embedPullMeta(
        tempIn,
        PullMeta(title: '', artist: '', album: '', lyrics: doc),
      );
      if (tagged == tempIn) return false;
      final outcome = await MediaWrites.retagWithConsent(
        uri: song.uri.toString(),
        srcPath: tagged,
        path: song.path,
      );
      ArchLog.i('doctor', 'finder retag "${song.title}": ${outcome.name}');
      if (outcome == WriteOutcome.failed && mounted) {
        setState(() => _status = 'Saved to cache, but the file kept its old lyrics.');
      }
      return outcome == WriteOutcome.ok;
    } finally {
      for (final p in [tempIn, tagged]) {
        if (p == null) continue;
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }
}
