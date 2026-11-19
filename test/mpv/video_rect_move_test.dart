import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/player_windows.dart';
import 'package:plezy/mpv/video.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/pump.dart';

void main() {
  // The Old School corner window keeps its size when the window is only
  // widened, and slides along the right edge. Reporting on size changes alone
  // left the native video where it was (Windows, 2026-10-14).
  testWidgets('a window resize that only moves the video re-sends its rect', (tester) async {
    final calls = <MethodCall>[];
    final eventCalls = <MethodCall>[];
    List<Map<Object?, Object?>> rects() =>
        calls.where((c) => c.method == 'setVideoRect').map((c) => c.arguments as Map<Object?, Object?>).toList();

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        calls.add(call);
        return call.method == 'initialize' ? true : null;
      },
      eventHandler: (call) async {
        eventCalls.add(call);
        return null;
      },
      testBody: () async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 600);
        addTearDown(tester.view.reset);
        final player = PlayerWindows();

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [Positioned(top: 0, right: 0, width: 160, height: 90, child: Video(player: player))],
            ),
          ),
        );
        await pumpUntil(tester, () => rects().isNotEmpty, describe: () => '${rects()}');
        expect(rects().last, containsPair('left', 640));

        tester.view.physicalSize = const Size(1000, 600);
        await pumpUntil(tester, () => rects().last['left'] == 840, describe: () => '${rects()}');
        expect(rects().last, containsPair('right', 1000));
        expect(rects().last, containsPair('bottom', 90));

        await tester.pumpWidget(const SizedBox.shrink());
        unawaited(player.dispose());
        await pumpUntil(
          tester,
          () => calls.any((call) => call.method == 'dispose') && eventCalls.any((call) => call.method == 'cancel'),
          describe: () => 'calls=${calls.map((c) => c.method).toList()}',
        );
      },
    );
  });

  // Car screens draw the app through Transform.scale with a MediaQuery whose
  // pixel ratio carries the same scale (_scaledSurface in main.dart). The rect
  // must come out in real screen pixels, not scaled twice (Tesla Screenmate,
  // 2026-11-19: the corner window's video sat 1.35x too far right).
  testWidgets('a scaled app surface sends the real screen rect', (tester) async {
    final calls = <MethodCall>[];
    final eventCalls = <MethodCall>[];
    List<Map<Object?, Object?>> rects() =>
        calls.where((c) => c.method == 'setVideoRect').map((c) => c.arguments as Map<Object?, Object?>).toList();

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        calls.add(call);
        return call.method == 'initialize' ? true : null;
      },
      eventHandler: (call) async {
        eventCalls.add(call);
        return null;
      },
      testBody: () async {
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = const Size(1200, 900);
        addTearDown(tester.view.reset);
        final player = PlayerWindows();

        // 800x600 logical, drawn at scale 2 from a 400x300 inner surface.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) {
                final outer = MediaQuery.of(context);
                return Transform.scale(
                  scale: 2,
                  alignment: Alignment.topLeft,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 400,
                      height: 300,
                      child: MediaQuery(
                        data: outer.copyWith(size: const Size(400, 300), devicePixelRatio: outer.devicePixelRatio * 2),
                        child: Stack(
                          children: [
                            Positioned(top: 0, right: 0, width: 100, height: 50, child: Video(player: player)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await pumpUntil(tester, () => rects().isNotEmpty, describe: () => '${rects()}');
        // Inner (300,0)-(400,50) -> logical (600,0)-(800,100) -> physical x1.5.
        expect(rects().last, containsPair('left', 900));
        expect(rects().last, containsPair('top', 0));
        expect(rects().last, containsPair('right', 1200));
        expect(rects().last, containsPair('bottom', 150));
        expect(rects().last, containsPair('devicePixelRatio', 1.5));

        await tester.pumpWidget(const SizedBox.shrink());
        unawaited(player.dispose());
        await pumpUntil(
          tester,
          () => calls.any((call) => call.method == 'dispose') && eventCalls.any((call) => call.method == 'cancel'),
          describe: () => 'calls=${calls.map((c) => c.method).toList()}',
        );
      },
    );
  });
}
