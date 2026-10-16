import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/screens/video_player/widgets/playback_corner.dart';

class _StatePlayer extends Fake implements Player {
  @override
  final PlayerState state;

  _StatePlayer(this.state);
}

MediaItem _film({String? library = 'Movies', MediaKind kind = MediaKind.movie}) => MediaItem.plex(
  id: 'm1',
  kind: kind,
  title: 'Real Steel',
  year: 2011,
  contentRating: 'PG-13',
  durationMs: const Duration(hours: 2, minutes: 7).inMilliseconds,
  libraryTitle: library,
);

MediaItem _episode({String? library = 'TV'}) => MediaItem.plex(
  id: 'e1',
  kind: MediaKind.episode,
  title: 'Pilot',
  grandparentTitle: 'Firefly',
  parentIndex: 1,
  index: 2,
  libraryTitle: library,
);

/// Runs [body] with the gate as a desktop sees it.
Future<void> _onDesktop(WidgetTester tester, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<bool> _shows(WidgetTester tester, MediaItem item) async {
  late bool result;
  final gate = PlaybackCornerGate(onChanged: () {});
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          result = gate.shows(context, item);
          return const SizedBox();
        },
      ),
    ),
  );
  return result;
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  group('Which items get the poster corner', () {
    testWidgets('films and episodes from Movies, TV and courses', (tester) async {
      await _onDesktop(tester, () async {
        expect(await _shows(tester, _film()), isTrue);
        expect(await _shows(tester, _episode()), isTrue);
        expect(await _shows(tester, _episode(library: 'Master Class')), isTrue);
      });
    });

    testWidgets('never YouTube or music videos, whatever the case', (tester) async {
      await _onDesktop(tester, () async {
        expect(await _shows(tester, _episode(library: 'YouTube')), isFalse);
        expect(await _shows(tester, _film(library: 'youtube')), isFalse);
        expect(await _shows(tester, _film(library: 'Music Videos')), isFalse);
      });
    });

    testWidgets('never a clip or a track', (tester) async {
      await _onDesktop(tester, () async {
        expect(await _shows(tester, _film(kind: MediaKind.clip)), isFalse);
        expect(await _shows(tester, _film(kind: MediaKind.track)), isFalse);
      });
    });

    testWidgets('never on a phone', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      try {
        expect(await _shows(tester, _film()), isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Poster corner', () {
    Widget page(MediaItem item, {bool visible = true}) => MaterialApp(
      home: Center(
        child: Stack(
          children: [
            PlaybackCorner(
              metadata: item,
              player: _StatePlayer(
                const PlayerState(duration: Duration(hours: 2, minutes: 7), position: Duration(hours: 1)),
              ),
              controlsVisible: visible,
            ),
          ],
        ),
      ),
    );

    testWidgets('a film: name, details, clock and when it ends', (tester) async {
      await _onDesktop(tester, () async {
        await tester.pumpWidget(page(_film()));
        expect(find.text('Real Steel'), findsOneWidget);
        expect(find.text('2011 · PG-13 · 2 h 7 min'), findsOneWidget);
        expect(find.textContaining('Ends at'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('arrives step by step each time the controls come up', (tester) async {
      await _onDesktop(tester, () async {
        await tester.pumpWidget(page(_film(), visible: false));
        await tester.pumpWidget(page(_film()));
        await tester.pump(const Duration(milliseconds: 120));
        // Early on the details have not faded in yet.
        final details = find.ancestor(of: find.text('2011 · PG-13 · 2 h 7 min'), matching: find.byType(FadeTransition));
        expect(tester.widget<FadeTransition>(details.first).opacity.value, 0);
        await tester.pump(const Duration(seconds: 3));
        expect(tester.widget<FadeTransition>(details.first).opacity.value, 1);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('an episode: show name and its season, number and name', (tester) async {
      await _onDesktop(tester, () async {
        await tester.pumpWidget(page(_episode()));
        expect(find.text('Firefly'), findsOneWidget);
        expect(find.text('S1 · E2 · Pilot'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('hidden with the controls, and never shrinks a loose Stack', (tester) async {
      await _onDesktop(tester, () async {
        await tester.pumpWidget(page(_film(), visible: false));
        await tester.pumpAndSettle();
        final opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
        expect(opacity.opacity, 0);
        expect(
          tester.getSize(find.descendant(of: find.byType(Center), matching: find.byType(Stack)).first),
          tester.getSize(find.byType(Center)),
        );
        await tester.pumpWidget(const SizedBox());
      });
    });
  });
}
