import '../media/media_item.dart';
import '../media/media_library.dart';

/// One library's share of a search, shown under its own heading.
/// [subtitle] names the server for libraries on servers the user does not own.
class SearchResultSection {
  final String key;
  final String title;
  final String? subtitle;
  final List<MediaItem> items;

  const SearchResultSection({required this.key, required this.title, this.subtitle, required this.items});
}

/// Splits ranked search results into one section per library.
///
/// Sections from [ownServerIds] come first, then each other server's in
/// turn. Within a server, sections follow [libraries] — the user's
/// main-screen library order — and a library missing from it (or a result
/// with no library) comes after the ones in it.
///
/// Within a section, results are sorted by release date, newest first. A
/// section holding anything not yet released (a "Coming Soon" library of
/// trailers) is sorted oldest first instead, so the next release leads.
/// Results with no date go last, in relevance order.
List<SearchResultSection> sectionSearchResults(
  List<MediaItem> items, {
  required Set<String> ownServerIds,
  required List<MediaLibrary> libraries,
  required String? Function(String serverId) serverNameOf,
  DateTime? now,
}) {
  if (items.isEmpty) return const [];

  final libraryIndex = {for (final (i, library) in libraries.indexed) library.globalKey: i};
  final libraryTitles = {for (final library in libraries) library.globalKey: library.title};
  final unlisted = libraries.length;

  final buckets = <String, List<MediaItem>>{};
  for (final item in items) {
    buckets.putIfAbsent(item.libraryGlobalKey ?? '${item.serverId ?? ''}:', () => []).add(item);
  }

  // A server ranks by its earliest library in the user's order; among
  // servers with none listed, by first appearance in the ranked results.
  final serverRank = <String?, int>{};
  for (final (i, entry) in buckets.entries.indexed) {
    final serverId = entry.value.first.serverId;
    final rank = (libraryIndex[entry.key] ?? unlisted) * buckets.length + i;
    final current = serverRank[serverId];
    if (current == null || rank < current) serverRank[serverId] = rank;
  }

  final today = _dateKey(now ?? DateTime.now());
  final relevance = Map<MediaItem, int>.identity();
  for (final (i, item) in items.indexed) {
    relevance[item] = i;
  }

  final sections = <({int own, int server, int library, int order, SearchResultSection section})>[];
  for (final (i, entry) in buckets.entries.indexed) {
    final bucketItems = entry.value;
    final first = bucketItems.first;
    final serverId = first.serverId;
    final isOwn = ownServerIds.contains(serverId);
    final serverName = serverId == null ? null : (first.serverName ?? serverNameOf(serverId));

    String? libraryTitle = libraryTitles[entry.key];
    for (final item in bucketItems) {
      libraryTitle ??= item.libraryTitle;
    }

    final upcoming = bucketItems.any((item) => (_releaseKey(item)?.compareTo(today) ?? 0) > 0);
    final sorted = [...bucketItems]
      ..sort((a, b) {
        final aKey = _releaseKey(a);
        final bKey = _releaseKey(b);
        if (aKey != null && bKey != null) {
          final byDate = upcoming ? aKey.compareTo(bKey) : bKey.compareTo(aKey);
          if (byDate != 0) return byDate;
        } else if (aKey != null) {
          return -1;
        } else if (bKey != null) {
          return 1;
        }
        return relevance[a]!.compareTo(relevance[b]!);
      });

    sections.add((
      own: isOwn ? 0 : 1,
      server: serverRank[serverId]!,
      library: libraryIndex[entry.key] ?? unlisted,
      order: i,
      section: SearchResultSection(
        key: entry.key,
        title: libraryTitle ?? serverName ?? '',
        subtitle: isOwn || libraryTitle == null ? null : serverName,
        items: sorted,
      ),
    ));
  }

  sections.sort((a, b) {
    for (final byField in [a.own - b.own, a.server - b.server, a.library - b.library, a.order - b.order]) {
      if (byField != 0) return byField;
    }
    return 0;
  });
  return [for (final entry in sections) entry.section];
}

/// `YYYY-MM-DD`, or `YYYY` when only the year is known; both compare
/// correctly as strings against a full date.
String? _releaseKey(MediaItem item) {
  final date = item.originallyAvailableAt;
  if (date != null && date.length >= 10) return date.substring(0, 10);
  return item.year?.toString().padLeft(4, '0');
}

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
