import '../../../models/plezyfin_subtitles.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/language_codes.dart';
import '../models/track_controls_state.dart';

/// Which external subtitle file in a fresh listing a PlezyFin download saved
/// (local/plans/subtitle-search-plezyfin.md), or null while it isn't listed
/// yet. Returns its stream index.
///
/// Stream ids can't be compared before and after: Jellyfin lists external
/// files first, so adding one shifts every index. So, in order:
/// 1. a file that wasn't in [DownloadedSubtitleHint.filesBefore] and matches
///    the download's language and forced flag (by path, or by count when the
///    server withholds paths);
/// 2. a file already there under Bazarr's own name for it
///    (`<video>.<lang>[.forced|.hi].<format>`): the download overwrote it, so
///    its index is unchanged and the file on disk is the new one;
/// 3. on the [lastTry] only, with no paths to go by: the first matching file.
int? findDownloadedPlezyFinSubtitle(
  List<PlezyFinExternalSubtitle> files, {
  required DownloadedSubtitleHint hint,
  bool lastTry = false,
}) {
  final language = _twoLetter(hint.languageCode);
  bool matches(PlezyFinExternalSubtitle file) {
    final fileLanguage = _twoLetter(file.language);
    if (language != null && fileLanguage != null && fileLanguage != language) return false;
    if (file.forced != hint.forced) return false;
    // Older servers never flag hearing impaired, so only a flag on a file
    // that wasn't asked for rules it out.
    return hint.hearingImpaired || !file.hearingImpaired;
  }

  final candidates = files.where(matches).toList();
  if (candidates.isEmpty) return null;
  final pathsShown = files.any((file) => file.path != null);
  final before = hint.filesBefore;

  if (before != null) {
    if (pathsShown) {
      final known = {for (final file in before) ?file.path};
      for (final file in candidates) {
        if (file.path != null && !known.contains(file.path)) return file.index;
      }
    } else if (files.length > before.length) {
      return candidates.first.index;
    }
  }

  if (language != null) {
    final kind = hint.forced ? '.forced' : (hint.hearingImpaired ? '.hi' : '');
    final suffix = '.$language$kind.${(hint.format ?? 'srt').toLowerCase()}';
    for (final file in candidates) {
      final path = file.path?.toLowerCase();
      if (path == null || !path.endsWith(suffix)) continue;
      if (before == null || before.any((old) => old.path?.toLowerCase() == path)) return file.index;
    }
  }

  if (lastTry && !pathsShown) return candidates.first.index;
  return null;
}

String? _twoLetter(String? code) {
  if (code == null || code.isEmpty) return null;
  return LanguageCodes.getIso6391Code(code) ?? code.toLowerCase();
}

/// What [pollForDownloadedPlezyFinSubtitle] found: the stream index, or why
/// there is none.
typedef PlezyFinSubtitlePollResult = ({int? index, bool superseded});

/// After a PlezyFin download: read the item's files every [interval], up to
/// [attempts] times (2 s x 7, about 15 s), one request at a time, until
/// [findDownloadedPlezyFinSubtitle] names the new file. Stops as soon as it
/// does, or when [isCurrent] says the player moved on. A failed read is
/// logged and the next one tried; nothing is retried after the last.
Future<PlezyFinSubtitlePollResult> pollForDownloadedPlezyFinSubtitle({
  required Future<List<PlezyFinExternalSubtitle>?> Function() fetch,
  required DownloadedSubtitleHint hint,
  required bool Function() isCurrent,
  Duration interval = const Duration(seconds: 2),
  int attempts = 7,
}) async {
  for (var attempt = 1; attempt <= attempts; attempt++) {
    await Future<void>.delayed(interval);
    if (!isCurrent()) return (index: null, superseded: true);
    try {
      final files = await fetch();
      if (!isCurrent()) return (index: null, superseded: true);
      if (files == null) continue;
      final index = findDownloadedPlezyFinSubtitle(files, hint: hint, lastTry: attempt == attempts);
      if (index != null) return (index: index, superseded: false);
    } catch (e) {
      appLogger.w('PlezyFin subtitle download poll failed', error: e);
      if (!isCurrent()) return (index: null, superseded: true);
    }
  }
  return (index: null, superseded: false);
}
