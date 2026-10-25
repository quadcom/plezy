import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/media/ids.dart';
import 'package:plezy/screens/old_school/old_school_controller.dart';
import 'package:plezy/services/library_events/old_school_guide_events.dart';

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

  // local/plans/old-school-live-guide.md, PlezyFin PLAN_PFN_87: the server's
  // change notices refresh only the changed channels, batched.
  group('OldSchoolController live guide', () {
    Map<String, Object?> entry(String itemId, DateTime start, Duration length) => {
      'kind': 'show',
      'itemType': 'Movie',
      'itemId': itemId,
      'name': itemId,
      'start': start.toIso8601String(),
      'end': start.add(length).toIso8601String(),
    };

    test('a notice re-fetches the named channels once and replaces their entries', () async {
      final guideCalls = <Map<String, String>>[];
      var moved = false;
      final client = testJellyfinClient(
        handler: (request) async {
          final path = request.url.path;
          if (path.endsWith('/PlezyFin/OldSchool/Channels')) return jsonResponse(<Object?>[]);
          if (path.endsWith('/PlezyFin/OldSchool/Guide')) {
            final query = request.url.queryParameters;
            guideCalls.add(query);
            final start = DateTime.parse(query['start']!);
            final serverTime = DateTime.now().toUtc().toIso8601String();
            // The first block holds both channels; the background block is empty.
            if (query['hours'] == '12') return jsonResponse({'ServerTime': serverTime, 'Channels': <Object?>[]});
            final film = moved
                ? entry('film', start.add(const Duration(minutes: 32)), const Duration(minutes: 90))
                : entry('film', start.add(const Duration(minutes: 30)), const Duration(minutes: 90));
            return jsonResponse({
              'ServerTime': serverTime,
              'Channels': [
                {
                  'ChannelId': 'engage',
                  'Entries': [film],
                },
                if (query['channelIds'] == null)
                  {
                    'ChannelId': 'other',
                    'Entries': [entry('other-film', start, const Duration(hours: 2))],
                  },
              ],
            });
          }
          return http.Response('{}', 404);
        },
      );
      final events = OldSchoolGuideEvents();
      final controller = OldSchoolController(client, guideEvents: events);
      addTearDown(controller.dispose);
      await controller.load();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guideCalls, hasLength(2));
      final start = controller.guideStart!;

      // Another server's notice, and one outside the loaded window, are ignored.
      events.notifyChanged(
        OldSchoolGuideChange(
          serverId: ServerId('someone-else'),
          channelIds: {'engage'},
          from: start,
          to: start.add(const Duration(hours: 1)),
        ),
      );
      events.notifyChanged(
        OldSchoolGuideChange(
          serverId: client.serverId,
          channelIds: {'engage'},
          from: start.add(const Duration(days: 6)),
          to: start.add(const Duration(days: 6, hours: 1)),
        ),
      );
      // Two notices inside the batch: one call.
      moved = true;
      events.notifyChanged(
        OldSchoolGuideChange(
          serverId: client.serverId,
          channelIds: {'engage'},
          from: start.add(const Duration(minutes: 30)),
          to: start.add(const Duration(hours: 1)),
        ),
      );
      events.notifyChanged(
        OldSchoolGuideChange(
          serverId: client.serverId,
          channelIds: {'engage'},
          from: start.add(const Duration(hours: 1)),
          to: start.add(const Duration(hours: 2)),
        ),
      );
      await Future<void>.delayed(OldSchoolController.changeBatch + const Duration(milliseconds: 500));

      expect(guideCalls, hasLength(3));
      expect(guideCalls[2]['channelIds'], 'engage');
      expect(DateTime.parse(guideCalls[2]['start']!), start.add(const Duration(minutes: 30)));
      expect(guideCalls[2]['hours'], '2');
      // The moved film shows once, at its new time; the other channel is untouched.
      final films = controller.entriesFor('engage');
      expect(films, hasLength(1));
      expect(films.single.start, start.add(const Duration(minutes: 62)));
      expect(controller.entriesFor('other'), hasLength(1));
    });

    test('a socket reconnect re-fetches everything loaded, once', () async {
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
      final events = OldSchoolGuideEvents();
      final controller = OldSchoolController(client, guideEvents: events);
      addTearDown(controller.dispose);
      await controller.load();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guideCalls, hasLength(2));

      events.notifyConnected(client.serverId);
      events.notifyConnected(client.serverId);
      await Future<void>.delayed(OldSchoolController.changeBatch + const Duration(milliseconds: 500));

      // 15 loaded hours in one call, every channel.
      expect(guideCalls, hasLength(3));
      expect(guideCalls[2].containsKey('channelIds'), isFalse);
      expect(DateTime.parse(guideCalls[2]['start']!), controller.guideStart);
      expect(guideCalls[2]['hours'], '15');
    });
  });
}
