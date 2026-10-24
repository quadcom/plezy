import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/models/old_school.dart';
import 'package:plezy/screens/old_school/old_school_controller.dart';
import 'package:plezy/screens/video_player/old_school_session.dart';

import '../../test_helpers/backend_client_fixtures.dart';

void main() {
  // local/plans/old-school-open-on-guide.md: the start-up channel opens in
  // the guide's corner window; every other tune opens full screen.
  group('OldSchoolSessionArgs.startInGuide', () {
    final tune = OldSchoolTune.fromJson('c2', {
      'serverTime': '2026-10-14T01:30:00Z',
      'now': {
        'kind': 'show',
        'itemType': 'Movie',
        'itemId': 'heat',
        'name': 'Heat',
        'start': '2026-10-14T01:00:00Z',
        'end': '2026-10-14T04:00:00Z',
      },
    }, receivedAt: DateTime.utc(2026, 10, 14, 1, 30))!;

    OldSchoolController controller() {
      final c = OldSchoolController(testJellyfinClient(handler: (_) async => http.Response('{}', 404)));
      addTearDown(c.dispose);
      return c;
    }

    test('a pick opens full screen', () {
      final args = OldSchoolSessionArgs(controller: controller(), tune: tune);
      expect(args.startInGuide, isFalse);
      expect(OldSchoolPlayerState().fullScreen, isTrue);
    });

    test('the start-up channel opens with the guide showing', () {
      final args = OldSchoolSessionArgs(controller: controller(), tune: tune, startInGuide: true);
      expect(args.startInGuide, isTrue);
    });
  });

  // local/plans/old-school-standby-card.md: what covers a standby gap and
  // when the channel is asked again.
  group('standby gap', () {
    final received = DateTime.utc(2026, 10, 24, 20, 47, 50);

    OldSchoolTune gap({Map<String, dynamic> filler = const {}, String? nextStart}) => OldSchoolTune.fromJson('engage', {
      'serverTime': '2026-10-24T20:47:50Z',
      'now': {'kind': 'standby', 'start': '2026-10-24T20:47:49Z', 'end': '2026-10-24T20:51:22Z', ...filler},
      if (nextStart != null)
        'next': {
          'kind': 'trailer',
          'itemId': 't1',
          'name': 'Trailer',
          'start': nextStart,
          'end': '2026-10-24T20:53:00Z',
        },
    }, receivedAt: received)!;

    test('a long gap is asked again every minute', () {
      final tune = gap(nextStart: '2026-10-24T20:51:22Z');
      expect(OldSchoolPlayerState.standbyWait(tune, received), OldSchoolPlayerState.standbyRecheck);
    });

    test('the last stretch waits for the next start, plus a second', () {
      final tune = gap(nextStart: '2026-10-24T20:51:22Z');
      final late = received.add(const Duration(minutes: 3));
      expect(OldSchoolPlayerState.standbyWait(tune, late), const Duration(seconds: 33));
    });

    test('a next start already past tunes at once; no next waits a minute', () {
      final tune = gap(nextStart: '2026-10-24T20:47:00Z');
      expect(OldSchoolPlayerState.standbyWait(tune, received), Duration.zero);
      expect(OldSchoolPlayerState.standbyWait(gap(), received), OldSchoolPlayerState.standbyRecheck);
    });

    test('the layer: picture, video (nothing over it) or the plain card', () {
      final state = OldSchoolPlayerState();
      expect(state.standbyLayer, OldSchoolStandbyLayer.none);
      state.standbyTune = gap();
      expect(state.standbyLayer, OldSchoolStandbyLayer.card);
      state.standbyTune = gap(filler: {'fillerItemId': 'p1', 'fillerKind': 'image'});
      expect(state.standbyLayer, OldSchoolStandbyLayer.image);
      state.standbyTune = gap(filler: {'fillerItemId': 'v1', 'fillerKind': 'video'});
      expect(state.standbyLayer, OldSchoolStandbyLayer.none);
      state.fillerFailed = true;
      expect(state.standbyLayer, OldSchoolStandbyLayer.card);
    });
  });
}
