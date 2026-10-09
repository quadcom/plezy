import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/screens/season/season_detail_screen.dart';
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

class _ShowClient implements MediaServerClient {
  _ShowClient({required this.seasons, required this.episodes, this.onDeck});

  final List<MediaItem> seasons;
  final Map<String, List<MediaItem>> episodes;
  final MediaItem? onDeck;

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
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  final seasons = [_season(1), _season(2)];
  final episodes = {
    's1': [_episode(1, 1, viewCount: 1), _episode(1, 2, viewCount: 1)],
    's2': [_episode(2, 1, viewCount: 1), _episode(2, 2), _episode(2, 3)],
  };

  Future<void> pump(WidgetTester tester, Widget home, {MediaItem? onDeck}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final servers = testMultiServer(
      clients: [_ShowClient(seasons: seasons, episodes: episodes, onDeck: onDeck)],
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
}
