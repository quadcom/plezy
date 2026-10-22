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
}
