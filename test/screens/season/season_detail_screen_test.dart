import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/screens/season/season_detail_screen.dart';
import 'package:plezy/screens/season/season_poster_row.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';

const _serverId = 'srv-season';

const _show = PlexMediaItem(
  id: 'show',
  kind: MediaKind.show,
  title: 'The Expanse',
  summary: 'A show about space.',
  year: 2015,
  contentRating: 'TV-14',
  serverId: _serverId,
);

PlexMediaItem _season(int n) => PlexMediaItem(
  id: 's$n',
  kind: MediaKind.season,
  title: 'Season $n',
  index: n,
  parentId: 'show',
  parentTitle: 'The Expanse',
  summary: 'Season $n summary.',
  serverId: _serverId,
);

PlexMediaItem _episode(int season, int n, {int? viewCount}) => PlexMediaItem(
  id: 'e$season-$n',
  kind: MediaKind.episode,
  title: 'Episode title $season-$n',
  summary: 'What happens in $season-$n.',
  index: n,
  parentIndex: season,
  parentId: 's$season',
  grandparentId: 'show',
  durationMs: 2700000,
  viewCount: viewCount,
  serverId: _serverId,
);

/// A not-yet-aired placeholder, as PlezyFin lists it from Sonarr.
PlexMediaItem _upcoming(int season, int n, {String? title, String? summary}) => PlexMediaItem(
  id: 'u$season-$n',
  kind: MediaKind.episode,
  title: title,
  summary: summary,
  index: n,
  parentIndex: season,
  parentId: 's$season',
  grandparentId: 'show',
  originallyAvailableAt: '2026-10-23',
  serverId: _serverId,
  raw: const {
    'LocationType': 'Virtual',
    'ProviderIds': {'Sonarr': '1'},
  },
);

/// A virtual episode that is not one of Sonarr's upcoming ones (a missing one).
PlexMediaItem _missing(int season, int n) => PlexMediaItem(
  id: 'm$season-$n',
  kind: MediaKind.episode,
  title: 'Missing $season-$n',
  index: n,
  parentIndex: season,
  parentId: 's$season',
  grandparentId: 'show',
  serverId: _serverId,
  raw: const {'LocationType': 'Virtual'},
);

class _ShowClient implements MediaServerClient {
  _ShowClient({required this.seasons, required this.episodes, this.onDeck, this.extras = const {}});

  final List<MediaItem> seasons;
  final Map<String, List<MediaItem>> episodes;
  final MediaItem? onDeck;
  final Map<String, List<MediaItem>> extras;

  @override
  final ServerId serverId = ServerId(_serverId);
  @override
  final String serverName = 'Server';

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    if (id == _show.id) return (item: _show, onDeckEpisode: onDeck);
    return (item: seasons.firstWhere((s) => s.id == id), onDeckEpisode: null);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async => seasons;

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final all = episodes[parentId] ?? const <MediaItem>[];
    return LibraryPage(items: all, totalCount: all.length);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final all = [for (final list in episodes.values) ...list];
    return LibraryPage(items: all, totalCount: all.length);
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => extras[id] ?? const [];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  final seasons = [_season(1), _season(2)];
  final episodes = {
    's1': [_episode(1, 1, viewCount: 1), _episode(1, 2, viewCount: 1)],
    's2': [_episode(2, 1, viewCount: 1), _episode(2, 2), _episode(2, 3)],
  };

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    MediaItem? onDeck,
    Map<String, List<MediaItem>> extras = const {},
    Map<String, List<MediaItem>>? episodeMap,
    List<MediaItem>? seasonList,
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final servers = testMultiServer(
      clients: [
        _ShowClient(seasons: seasonList ?? seasons, episodes: episodeMap ?? episodes, onDeck: onDeck, extras: extras),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>.value(
        value: servers.provider,
        child: TranslationProvider(
          child: MaterialApp(theme: monoTheme(dark: true), home: home),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('opens on the season of the next episode, with its episodes in a row', (tester) async {
    await pump(tester, const SeasonDetailScreen(metadata: _show), onDeck: _episode(2, 2));

    expect(find.text('THE EXPANSE'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.text('1 of 3 episodes watched'), findsOneWidget);
    expect(find.text('Resume: Episode 2 – Episode title 2-2'), findsOneWidget);
    expect(find.text('Season 2 summary.'), findsOneWidget);

    final titles = tester.widgetList<Text>(find.textContaining(RegExp(r'^Episode title 2-\d$')));
    expect(titles.map((t) => t.data), ['Episode title 2-1', 'Episode title 2-2', 'Episode title 2-3']);

    // The next episode is selected; only its description shows.
    expect(find.textContaining('Episode 2: Episode title 2-2'), findsOneWidget);
    expect(find.text('What happens in 2-2.'), findsOneWidget);
    expect(find.text('What happens in 2-3.'), findsNothing);

    // A tap picks another episode; its description replaces the other.
    await tester.tap(find.text('3'));
    await tester.pump();
    expect(find.text('What happens in 2-3.'), findsOneWidget);
    expect(find.text('What happens in 2-2.'), findsNothing);
  });

  group('upcoming episodes (local/plans/upcoming-episodes.md)', () {
    testWidgets('show greyed with their air date, and are not counted', (tester) async {
      await pump(
        tester,
        const SeasonDetailScreen(metadata: _show, initialSeasonId: 's2'),
        episodeMap: {
          ...episodes,
          's2': [...episodes['s2']!, _upcoming(2, 4, title: 'How to Build the Box'), _missing(2, 5)],
        },
      );

      expect(find.text('UPCOMING'), findsOneWidget);
      expect(find.text('AIRS FRI'), findsOneWidget);
      expect(find.text('23 Oct'), findsOneWidget);
      expect(find.text('Airs Fri 23 Oct'), findsOneWidget);
      expect(find.text('How to Build the Box'), findsOneWidget);
      // Other virtual episodes stay off the page.
      expect(find.text('Missing 2-5'), findsNothing);
      // The header counts the three aired episodes only.
      expect(find.textContaining('·  3 episodes  ·'), findsOneWidget);
      expect(find.text('1 of 3 episodes watched'), findsOneWidget);

      // Picking it shows its air date and "No details yet", and a second tap
      // plays nothing: the page stays.
      await tester.tap(find.text('4'));
      await tester.pump();
      expect(find.textContaining('Episode 4: How to Build the Box'), findsOneWidget);
      expect(find.textContaining('Airs Friday 23 October'), findsOneWidget);
      expect(find.text('No details yet'), findsOneWidget);
      await tester.tap(find.text('4'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(SeasonDetailScreen), findsOneWidget);
      expect(find.text('No details yet'), findsOneWidget);
    });

    testWidgets('a season the server lists for upcoming episodes only says so', (tester) async {
      const upcomingSeason = PlexMediaItem(
        id: 's3',
        kind: MediaKind.season,
        title: 'Season 3',
        index: 3,
        parentId: 'show',
        parentTitle: 'The Expanse',
        serverId: _serverId,
        raw: {
          'LocationType': 'Virtual',
          'ProviderIds': {'Sonarr': 'season'},
        },
      );
      await pump(
        tester,
        const SeasonDetailScreen(metadata: upcomingSeason),
        seasonList: [...seasons, upcomingSeason],
        episodeMap: {
          ...episodes,
          's3': [_upcoming(3, 1, title: 'Premiere')],
        },
      );

      expect(find.text('Season 3'), findsOneWidget);
      expect(find.textContaining('Upcoming'), findsOneWidget);
      expect(find.textContaining('0 episodes'), findsNothing);
      expect(find.text('Premiere'), findsOneWidget);
      expect(find.text('Play'), findsNothing);
    });

    testWidgets('a season of upcoming episodes only has nothing to play', (tester) async {
      await pump(
        tester,
        const SeasonDetailScreen(metadata: _show, initialSeasonId: 's2'),
        episodeMap: {
          ...episodes,
          's2': [_upcoming(2, 1), _upcoming(2, 2)],
        },
      );

      expect(find.text('UPCOMING'), findsNWidgets(2));
      expect(find.text('TBA'), findsNWidgets(2));
      expect(find.text('Play'), findsNothing);
    });
  });

  testWidgets('opens the season it was asked for, at the episode it was asked for', (tester) async {
    await pump(tester, const SeasonDetailScreen(metadata: _show, initialSeasonId: 's1', initialEpisodeId: 'e1-2'));

    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('What happens in 1-2.'), findsOneWidget);
  });

  testWidgets('a flattened show puts every episode in one row, badged by season', (tester) async {
    await pump(tester, const SeasonDetailScreen(metadata: _show, wholeShow: true));

    expect(find.text('The Expanse'), findsOneWidget);
    expect(find.textContaining('2015  ·  TV-14  ·  5 episodes  ·  '), findsOneWidget);
    expect(find.text('3 of 5 episodes watched'), findsOneWidget);
    expect(find.text('S1 · E1'), findsOneWidget);
    expect(find.text('S2 · E3'), findsOneWidget);
  });

  testWidgets('a season opens on its own page', (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(mediaDetailRoute(metadata: _season(1))),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(SeasonDetailScreen), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
  });

  group('season trailers (PLAN_PMB_56)', () {
    PlexMediaItem trailer(String id, String title) =>
        PlexMediaItem(id: id, kind: MediaKind.clip, subtype: 'trailer', title: title, serverId: _serverId);

    testWidgets("a season with its own trailer offers it", (tester) async {
      await pump(
        tester,
        const SeasonDetailScreen(metadata: _show, initialSeasonId: 's2'),
        extras: {
          's2': [trailer('own2', 'The Expanse S02')],
        },
      );
      expect(find.text('Watch trailer'), findsOneWidget);
    });

    testWidgets("a season without one uses the show's trailer named for it", (tester) async {
      await pump(
        tester,
        const SeasonDetailScreen(metadata: _show, initialSeasonId: 's1'),
        extras: {
          'show': [trailer('t1', 'The Expanse S01'), trailer('t2', 'The Expanse S02')],
        },
      );
      expect(find.text('Watch trailer'), findsOneWidget);
    });

    testWidgets("a season never plays another season's trailer", (tester) async {
      await pump(
        tester,
        const SeasonDetailScreen(metadata: _show, initialSeasonId: 's1'),
        extras: {
          'show': [trailer('t2', 'The Expanse S02')],
          's2': [trailer('own2', 'The Expanse S02')],
        },
      );
      expect(find.text('Watch trailer'), findsNothing);
    });
  });

  testWidgets('season posters are labelled with the season, not the show', (tester) async {
    await pump(
      tester,
      Scaffold(
        body: SeasonPosterRow(
          seasons: [
            _season(1),
            _season(2),
            const PlexMediaItem(id: 's9', kind: MediaKind.season, index: 9),
          ],
          client: null,
          focusNodes: const [],
          onOpen: (_) {},
        ),
      ),
    );

    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.text('Season 9'), findsOneWidget);
    expect(find.text('The Expanse'), findsNothing);
  });
}
