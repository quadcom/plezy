import 'media_item.dart';

/// Master Class courses, as served by PMB (plex-media-bridge). Fork-only.
///
/// On Plex a course is a show from PMB's custom metadata provider, whose guids
/// read `tv.plex.agents.custom.pmb.masterclass://show/pc-mc60`, with
/// `.../season/pc-mc60-s1` and `.../episode/pc-mc60-e1` below it. On Jellyfin
/// PMB marks the series with `ProviderIds["PmbMasterClass"] = "pc-mc60"`.
const String plexCourseGuidScheme = 'tv.plex.agents.custom.pmb.masterclass://';
const String jellyfinCourseProviderId = 'PmbMasterClass';

final _levelSuffix = RegExp(r'-[se]\d+$');

/// The leading `Folder: <name> [pmb-<id>]` line PMB writes into a course
/// summary, with the blank line after it.
final _pmbFolderLine = RegExp(r'^Folder:[^\n]*\[pmb-[^\]\n]*\][^\n]*\n\s*');

extension MediaItemCourse on MediaItem {
  /// The course this item belongs to (`pc-<id>`) when it is a Master Class
  /// course, or one of its seasons or lessons on Plex; null otherwise.
  /// Jellyfin marks the series only, and only where its `ProviderIds` were
  /// fetched (detail requests ask for them; browse pages do not).
  String? get courseKey {
    final guid = this.guid;
    if (guid != null && guid.startsWith(plexCourseGuidScheme)) {
      final key = guid.substring(guid.lastIndexOf('/') + 1).replaceFirst(_levelSuffix, '');
      return key.isEmpty ? null : key;
    }
    final providerIds = raw?['ProviderIds'];
    if (providerIds is Map) {
      final key = providerIds[jellyfinCourseProviderId];
      if (key is String && key.isNotEmpty) return key;
    }
    return null;
  }

  bool get isCourse => courseKey != null;

  /// The course's instructors, from the people PMB names with the role
  /// "Instructor". Empty until PMB supplies them.
  List<String> get courseInstructors => [
    for (final role in roles ?? const [])
      if (role.role?.trim().toLowerCase() == 'instructor' && role.tag.trim().isNotEmpty) role.tag.trim(),
  ];
}

/// A course title split into who teaches and what is taught.
typedef CourseTitle = ({String instructor, String subject});

/// Splits a course title such as "Aaron Franklin Teaches Texas Style BBQ" or
/// "Bake Like a Pro With Joanne Chang". With [instructors] known (from PMB),
/// the subject is the title with their names and the joining word removed;
/// without them the title's own wording is used. Falls back to the whole
/// title as the subject when neither works.
CourseTitle splitCourseTitle(String title, {List<String> instructors = const []}) {
  final trimmed = title.trim();
  if (instructors.isNotEmpty) {
    final who = instructors.join(' & ');
    for (final name in instructors) {
      final escaped = RegExp.escape(name);
      final leading = RegExp('^$escaped\\s+teach(?:es)?\\s+', caseSensitive: false);
      if (leading.hasMatch(trimmed)) return (instructor: who, subject: trimmed.replaceFirst(leading, ''));
      final trailing = RegExp('\\s*[-–]?\\s*with\\s+$escaped.*\$', caseSensitive: false);
      if (trailing.hasMatch(trimmed)) return (instructor: who, subject: trimmed.replaceFirst(trailing, ''));
    }
    final fromTitle = _splitByWording(trimmed);
    return (instructor: who, subject: fromTitle?.subject ?? trimmed);
  }
  return _splitByWording(trimmed) ?? (instructor: '', subject: trimmed);
}

CourseTitle? _splitByWording(String title) {
  final teaches = RegExp(r'^(.+?)\s+Teach(?:es)?\s+(.+)$').firstMatch(title);
  if (teaches != null) return (instructor: teaches.group(1)!, subject: teaches.group(2)!);
  final withName = RegExp(r'^(.+?)\s*[-–]?\s+[Ww]ith\s+(.+)$').firstMatch(title);
  if (withName != null) return (instructor: withName.group(2)!, subject: withName.group(1)!);
  return null;
}

/// The course's trailer among its [extras] (PMB gives a course at most one,
/// from its `Trailers` folder). Plex names it as the show's primary extra;
/// otherwise the first extra marked as a trailer: Plex `subtype="trailer"`,
/// Jellyfin `Type`/`ExtraType` "Trailer". Same rule as the detail screen's
/// trailer button.
MediaItem? courseTrailer(MediaItem course, List<MediaItem> extras) {
  if (course case PlexMediaItem(:final trailerKey?)) {
    final primaryId = trailerKey.split('/').last;
    for (final extra in extras) {
      if (extra.id == primaryId) return extra;
    }
  }
  for (final extra in extras) {
    if (_isTrailer(extra)) return extra;
  }
  return null;
}

bool _isTrailer(MediaItem extra) {
  if (extra case PlexMediaItem(:final subtype?)) return subtype.toLowerCase() == 'trailer';
  final raw = extra.raw;
  return (raw?['ExtraType'] as String?)?.toLowerCase() == 'trailer' ||
      (raw?['Type'] as String?)?.toLowerCase() == 'trailer';
}

/// [summary] without PMB's leading `Folder: ... [pmb-...]` line. Adrian,
/// 2026-10-08: hide it in Plezy until PMB stops writing it.
String? courseSummary(String? summary) {
  if (summary == null) return null;
  return summary.replaceFirst(_pmbFolderLine, '').trim();
}
