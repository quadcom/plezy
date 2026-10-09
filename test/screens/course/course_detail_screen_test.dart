import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/course/course_detail_screen.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';

const _serverId = 'srv-course';

PlexMediaItem _lesson(int n, String title, {int? viewCount, int? viewOffsetMs}) => PlexMediaItem(
  id: 'l$n',
  kind: MediaKind.episode,
  guid: 'tv.plex.agents.custom.pmb.masterclass://episode/pc-mc60-e$n',
  title: title,
  summary: 'Notes for $title.',
  index: n,
  parentIndex: 1,
  durationMs: 600000,
  viewCount: viewCount,
  viewOffsetMs: viewOffsetMs,
  serverId: _serverId,
);

class _CourseClient implements MediaServerClient {
  _CourseClient(this.course, this.lessons, {this.onDeck});

  final MediaItem course;
  final List<MediaItem> lessons;
  final MediaItem? onDeck;

  @override
  final ServerId serverId = ServerId(_serverId);
  @override
  final String serverName = 'Server';

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async => (item: course, onDeckEpisode: onDeck);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async => lessons.reversed.toList();

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  Future<void> pumpCourse(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const course = PlexMediaItem(
      id: '111085',
      kind: MediaKind.show,
      guid: 'tv.plex.agents.custom.pmb.masterclass://show/pc-mc60',
      title: 'Aaron Franklin Teaches Texas Style BBQ',
      summary: 'Folder: Aaron Franklin Teaches Texas Style BBQ [pmb-mc60]\n\nMeet your new instructor.',
      year: 2019,
      serverId: _serverId,
    );
    final lessons = [
      _lesson(1, 'Introduction', viewCount: 1),
      _lesson(2, 'Fire and Smoke', viewOffsetMs: 120000),
      _lesson(3, 'Smoke: Pork Butt'),
    ];
    final servers = testMultiServer(clients: [_CourseClient(course, lessons, onDeck: lessons[1])]);

    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>.value(
        value: servers.provider,
        child: TranslationProvider(
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: const CourseDetailScreen(metadata: course),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('shows the instructor, subject, progress and the resume lesson', (tester) async {
    await pumpCourse(tester);

    expect(find.text('AARON FRANKLIN'), findsOneWidget);
    expect(find.text('Texas Style BBQ'), findsOneWidget);
    expect(find.text('1 of 3 lessons watched'), findsOneWidget);
    expect(find.text('Resume: Lesson 2 – Fire and Smoke'), findsOneWidget);
    expect(find.text('Start over'), findsOneWidget);
    // PMB's Folder line is hidden; the rest of the summary shows.
    expect(find.text('Meet your new instructor.'), findsOneWidget);
    expect(find.textContaining('Folder:'), findsNothing);
  });

  testWidgets('lists lessons in order and shows the selected lesson\'s notes only', (tester) async {
    await pumpCourse(tester);

    final titles = tester.widgetList<Text>(
      find.textContaining(RegExp(r'^(Introduction|Fire and Smoke|Smoke: Pork Butt)$')),
    );
    expect(titles.map((t) => t.data), ['Introduction', 'Fire and Smoke', 'Smoke: Pork Butt']);

    // Opens on the lesson to resume.
    expect(find.textContaining('Lesson 2: Fire and Smoke'), findsOneWidget);
    expect(find.text('Notes for Fire and Smoke.'), findsOneWidget);
    expect(find.text('Notes for Smoke: Pork Butt.'), findsNothing);

    // A tap picks another lesson; its notes replace the others.
    await tester.tap(find.text('3'));
    await tester.pump();
    expect(find.textContaining('Lesson 3: Smoke: Pork Butt'), findsOneWidget);
    expect(find.text('Notes for Smoke: Pork Butt.'), findsOneWidget);
    expect(find.text('Notes for Fire and Smoke.'), findsNothing);
  });
}
