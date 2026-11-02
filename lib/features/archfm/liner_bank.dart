library;
import 'kokoro_voices.dart';

/// ArchFM liner bank: short host bites around the music. Solo
/// breaks only for v1 (duo handoffs are parked, see [DuoPlan]).
/// Selection is a pure function so it stays testable and never
/// touches the clock across an await.
///
/// Tokens filled at render time: {artist} {title} {nextArtist}
/// {nextTitle} {year} {genre} {bpm}. A template whose tokens are
/// missing falls back to a plain backsell, never an invented fact.

/// Liner shape. Combo (backsell plus intro in one breath) is the
/// one that sells the live-radio illusion.
enum LinerKind { stationId, backsell, intro, combo, context }

/// Daypart pack. Morning runs 5 to 11, then daytime, evening,
/// and late night. The pack picks the shelf; energy picks the cut.
enum Daypart { morning, daytime, evening, lateNight }

/// Energy tier from BPM when known. No BPM on file means the
/// daypart decides alone, never a guess.
enum Energy { chill, mid, high }

/// One liner template. [pinnedVoice] forces its host for that
/// break (gender-centric lines); null alternates with last break.
class LinerTemplate {
  final String id;
  final LinerKind kind;
  final String text;
  final KokoroVoice? pinnedVoice;
  final Set<Daypart> dayparts;
  final Set<Energy>? energies;

  const LinerTemplate({
    required this.id,
    required this.kind,
    required this.text,
    this.pinnedVoice,
    required this.dayparts,
    this.energies,
  });
}

const _allDay = {
  Daypart.morning,
  Daypart.daytime,
  Daypart.evening,
  Daypart.lateNight,
};

const _day = {Daypart.morning, Daypart.daytime, Daypart.evening};
const _night = {Daypart.evening, Daypart.lateNight};

/// V1 solo bank. Short on purpose: every liner stays under about
/// 12 seconds of speech or it stops feeling like FM.
const linerBank = <LinerTemplate>[
  LinerTemplate(
    id: 'id-1',
    kind: LinerKind.stationId,
    text: 'You are locked to Arch FM.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'id-2',
    kind: LinerKind.stationId,
    text: 'Arch FM, your music, hosted.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'back-1',
    kind: LinerKind.backsell,
    text: 'That was {artist} with {title}.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'back-2',
    kind: LinerKind.backsell,
    text: '{title} by {artist}, on Arch FM.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'back-era',
    kind: LinerKind.context,
    text: '{artist}, {year}, {album}. Still hits.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'back-genre',
    kind: LinerKind.context,
    text: 'Some {genre} for you, that was {artist}.',
    dayparts: _day,
  ),
  LinerTemplate(
    id: 'up-1',
    kind: LinerKind.intro,
    text: 'Up next, {nextArtist} with {nextTitle}.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'up-2',
    kind: LinerKind.intro,
    text: 'Coming up, {nextTitle} from {nextArtist}.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'combo-1',
    kind: LinerKind.combo,
    text: 'That was {artist} with {title}. Up next, {nextArtist}.',
    dayparts: _allDay,
  ),
  LinerTemplate(
    id: 'combo-2',
    kind: LinerKind.combo,
    text: '{title} on Arch FM. Stay here, {nextTitle} is next.',
    dayparts: _day,
  ),
  // Bella-leaning: smooth, warm, mornings and late nights.
  LinerTemplate(
    id: 'bella-morn-1',
    kind: LinerKind.stationId,
    text: 'Smooth start to your morning, I am Bella on Arch FM.',
    pinnedVoice: KokoroVoice.bella,
    dayparts: {Daypart.morning},
  ),
  LinerTemplate(
    id: 'bella-morn-2',
    kind: LinerKind.intro,
    text: 'Bella here, easing you into {nextTitle}.',
    pinnedVoice: KokoroVoice.bella,
    dayparts: {Daypart.morning},
  ),
  LinerTemplate(
    id: 'bella-night-1',
    kind: LinerKind.backsell,
    text: 'That last one was for the night owls. Bella on Arch FM.',
    pinnedVoice: KokoroVoice.bella,
    dayparts: _night,
  ),
  LinerTemplate(
    id: 'bella-night-2',
    kind: LinerKind.intro,
    text: 'Keeping it light, I am Bella with you.',
    pinnedVoice: KokoroVoice.bella,
    dayparts: {Daypart.lateNight},
  ),
  // Michael-leaning: drive energy, high BPM home turf.
  LinerTemplate(
    id: 'mike-high-1',
    kind: LinerKind.intro,
    text: 'Michael here, let us pick up the pace on Arch FM.',
    pinnedVoice: KokoroVoice.michael,
    dayparts: _allDay,
    energies: {Energy.high},
  ),
  LinerTemplate(
    id: 'mike-high-2',
    kind: LinerKind.backsell,
    text: 'That energy is all you. Michael on Arch FM.',
    pinnedVoice: KokoroVoice.michael,
    dayparts: _allDay,
    energies: {Energy.high, Energy.mid},
  ),
  LinerTemplate(
    id: 'mike-day-1',
    kind: LinerKind.stationId,
    text: 'No slow mornings on my watch. Michael, Arch FM.',
    pinnedVoice: KokoroVoice.michael,
    dayparts: {Daypart.morning, Daypart.daytime},
  ),
  LinerTemplate(
    id: 'tempo-1',
    kind: LinerKind.context,
    text: 'Keeping it at {bpm} BPM, this is Arch FM.',
    dayparts: _allDay,
    energies: {Energy.mid, Energy.high},
  ),
  LinerTemplate(
    id: 'era-1',
    kind: LinerKind.context,
    text: 'Taking you back to {year}.',
    dayparts: _allDay,
  ),
];

/// Daypart for an hour of day. Morning is 5 to 11 by house rule.
Daypart daypartForHour(int hour) {
  if (hour >= 5 && hour < 11) return Daypart.morning;
  if (hour >= 11 && hour < 18) return Daypart.daytime;
  if (hour >= 18 && hour < 23) return Daypart.evening;
  return Daypart.lateNight;
}

/// Energy tier for a BPM. Cutoffs are house defaults: chill under
/// 95, mid 95 to 125, high above 125.
Energy? energyForBpm(double? bpm) {
  if (bpm == null) return null;
  if (bpm < 95) return Energy.chill;
  if (bpm <= 125) return Energy.mid;
  return Energy.high;
}

/// Pick the next liner: daypart shelf first, energy second, then
/// the least recently used template. Pinned voice wins, otherwise
/// the voice alternates from the last break. Returns null only
/// when the bank is empty, which it never is.
({LinerTemplate liner, KokoroVoice voice})? resolveLiner({
  required DateTime now,
  double? bpm,
  required KokoroVoice lastVoice,
  required Set<String> recentIds,
}) {
  if (linerBank.isEmpty) return null;
  final part = daypartForHour(now.hour);
  final energy = energyForBpm(bpm);
  var shelf = linerBank.where((t) => t.dayparts.contains(part)).toList();
  if (shelf.isEmpty) shelf = linerBank.toList();
  if (energy != null) {
    final cut = shelf
        .where((t) => t.energies == null || t.energies!.contains(energy))
        .toList();
    if (cut.isNotEmpty) shelf = cut;
  }
  shelf.sort((a, b) {
    final ra = recentIds.contains(a.id) ? 1 : 0;
    final rb = recentIds.contains(b.id) ? 1 : 0;
    return ra.compareTo(rb);
  });
  final liner = shelf.first;
  final voice =
      liner.pinnedVoice ??
      (lastVoice == KokoroVoice.bella
          ? KokoroVoice.michael
          : KokoroVoice.bella);
  return (liner: liner, voice: voice);
}

/// Fill tokens from track metadata. Missing values fall back to a
/// plain backsell shape, never invented facts.
String fillLiner(
  String text, {
  String? artist,
  String? title,
  String? album,
  String? nextArtist,
  String? nextTitle,
  int? year,
  String? genre,
  double? bpm,
}) {
  var out = text;
  // Context liners need their facts: without a year or genre they
  // collapse to a plain backsell instead of bluffing.
  if ((text.contains('{year}') && (year == null || year <= 0)) ||
      (text.contains('{genre}') && (genre == null || genre.isEmpty)) ||
      (text.contains('{bpm}') && bpm == null)) {
    out = 'That was {artist} with {title}.';
  }
  final pairs = <String, String>{
    '{artist}': (artist == null || artist.isEmpty) ? 'that artist' : artist,
    '{title}': (title == null || title.isEmpty) ? 'that track' : title,
    '{album}': (album == null || album.isEmpty) ? 'that record' : album,
    '{nextArtist}':
        (nextArtist == null || nextArtist.isEmpty) ? 'more music' : nextArtist,
    '{nextTitle}':
        (nextTitle == null || nextTitle.isEmpty) ? 'more music' : nextTitle,
    '{year}': (year == null || year <= 0) ? '' : '$year',
    '{genre}': (genre == null || genre.isEmpty) ? '' : genre,
    '{bpm}': bpm == null ? '' : bpm.round().toString(),
  };
  pairs.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

/// Duo handoffs (Bella tosses to Michael and back) are parked for
/// v1: solo breaks only. The renderer chains clips, so a duo line
/// later is two synths in one file, no rework. Kept as a type so
/// the bank can grow turns without a schema change.
class DuoPlan {
  final String bellaTurn;
  final String michaelTurn;

  const DuoPlan({required this.bellaTurn, required this.michaelTurn});
}
