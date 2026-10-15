import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/screens/old_school/old_school_controller.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/http_fixtures.dart';

void main() {
  group('OldSchoolController.load', () {
    test('asks for a short first block, then fetches the next block on its own', () async {
      final guideCalls = <Map<String, String>>[];
      final client = testJellyfinClient(
        handler: (request) async {
          final path = request.url.path;
          if (path.endsWith('/PlezyFin/OldSchool/Channels')) return jsonResponse(<Object?>[]);
          if (path.endsWith('/PlezyFin/OldSchool/Guide')) {
            guideCalls.add(request.url.queryParameters);
            return jsonResponse({'ServerTime': DateTime.now().toUtc().toIso8601String(), 'Channels': <Object?>[]});
          }
          return http.Response('{}', 404);
        },
      );
      final controller = OldSchoolController(client);
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.error, isNull);
      expect(controller.guideEnd!.difference(controller.guideStart!), const Duration(hours: 3));

      // The background block follows without any scrolling.
      final grown = Completer<void>();
      void check() {
        if (!grown.isCompleted && controller.guideEnd!.difference(controller.guideStart!).inHours == 15) {
          grown.complete();
        }
      }

      controller.addListener(check);
      check();
      await grown.future.timeout(const Duration(seconds: 5));

      expect(guideCalls, hasLength(2));
      expect(guideCalls[0]['hours'], '3');
      expect(guideCalls[1]['hours'], '12');
      expect(DateTime.parse(guideCalls[1]['start']!), controller.guideStart!.add(const Duration(hours: 3)));
    });
  });
}
