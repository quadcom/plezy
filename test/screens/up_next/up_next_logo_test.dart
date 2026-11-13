import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/up_next/up_next_screen.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/optimized_media_image.dart';

void main() {
  const logoUrl = 'https://example.com/logo.png';
  const fallbackKey = Key('fallback');

  Widget host(Widget child) => MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(1920, 1080), devicePixelRatio: 1, disableAnimations: true),
      child: Center(child: child),
    ),
  );

  Finder loadingBox(WidgetTester tester) {
    final surface = Theme.of(tester.element(find.byType(Center))).colorScheme.surfaceContainerHighest;
    return find.byWidgetPredicate((w) => w is Container && w.color == surface);
  }

  testWidgets('a plain logo image shows a solid loading box (the bug)', (tester) async {
    await tester.pumpWidget(
      host(
        const OptimizedMediaImage(
          client: null,
          imagePath: logoUrl,
          imageType: ImageType.logo,
          width: 520,
          height: 104,
          fit: BoxFit.contain,
        ),
      ),
    );
    expect(loadingBox(tester), findsOneWidget);
  });

  testWidgets('the Up Next logo slot stays empty while the logo loads', (tester) async {
    await tester.pumpWidget(
      host(
        const UpNextLogo(
          client: null,
          logoPath: logoUrl,
          width: 520,
          height: 104,
          fallback: SizedBox(key: fallbackKey),
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(loadingBox(tester), findsNothing);
    expect(find.byKey(fallbackKey), findsNothing);
  });

  testWidgets('the preload asks for the same cached image the page shows', (tester) async {
    await tester.pumpWidget(
      host(
        const UpNextLogo(
          client: null,
          logoPath: logoUrl,
          width: 520,
          height: 104,
          fallback: SizedBox(key: fallbackKey),
        ),
      ),
    );
    final shown = tester.widget<Image>(find.byType(Image)).image;
    final preload = UpNextLogo.imageFor(
      tester.element(find.byType(UpNextLogo)),
      client: null,
      logoPath: logoUrl,
      width: 520,
      height: 104,
    );
    expect(preload, isNotNull);
    final shownKey = await shown.obtainKey(ImageConfiguration.empty);
    final preloadKey = await preload!.provider.obtainKey(ImageConfiguration.empty);
    expect(preloadKey, shownKey);
  });

  group('upNextLookaheadColumns', () {
    test('the next two to the right', () {
      expect(upNextLookaheadColumns(0, 10, 2), [1, 2]);
      expect(upNextLookaheadColumns(4, 10, 2), [5, 6]);
    });

    test('stops at the end of the row', () {
      expect(upNextLookaheadColumns(8, 10, 2), [9]);
      expect(upNextLookaheadColumns(9, 10, 2), isEmpty);
      expect(upNextLookaheadColumns(0, 1, 2), isEmpty);
    });
  });
}
