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
}
