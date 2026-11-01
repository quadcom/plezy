import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/models/old_school.dart';
import 'package:plezy/services/library_events/old_school_guide_events.dart';
import 'package:plezy/services/old_school_reminders.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

// local/plans/old-school-future-details.md, PlezyFin PLAN_PFN_100.
void main() {
  final start = DateTime.utc(2026, 11, 1, 21);

  Map<String, Object?> dto(String id, {DateTime? at}) => {
    'Id': id,
    'ChannelId': 'films',
    'ChannelNumber': 4,
    'ChannelName': 'Films',
    'ItemId': 'blade-runner',
    'Name': 'Blade Runner',
    'Start': (at ?? start).toIso8601String(),
    'End': (at ?? start).add(const Duration(hours: 2)).toIso8601String(),
    'OriginalStart': start.toIso8601String(),
    'Moved': false,
  };

  OldSchoolEntry entry({DateTime? at}) => OldSchoolEntry(
    kind: OldSchoolEntryKind.movie,
    itemId: 'blade-runner',
    start: at ?? start,
    end: (at ?? start).add(const Duration(hours: 2)),
    name: 'Blade Runner',
  );

  group('OldSchoolReminder.fromJson', () {
    test('reads the server shape', () {
      final r = OldSchoolReminder.fromJson({
        ...dto('r1'),
        'SeriesName': 'Columbo',
        'SeasonNumber': 2,
        'EpisodeNumber': 3,
        'Moved': true,
      })!;
      expect(r.id, 'r1');
      expect(r.channelNumber, 4);
      expect(r.title, 'Columbo');
      expect(r.start, start);
      expect(r.moved, isTrue);
      expect(r.matches('films', entry()), isTrue);
      expect(r.matches('news', entry()), isFalse);
    });

    test('a programme no longer scheduled has no start', () {
      final r = OldSchoolReminder.fromJson({...dto('r1'), 'Start': null})!;
      expect(r.start, isNull);
    });

    test('needs an id and a channel', () {
      expect(OldSchoolReminder.fromJson({'Id': 'r1'}), isNull);
      expect(OldSchoolReminder.fromJson('nope'), isNull);
    });
  });

  group('OldSchoolReminderService', () {
    test('a server without reminders offers none', () async {
      final client = testJellyfinClient(handler: (_) async => http.Response('{}', 404));
      final service = OldSchoolReminderService(events: OldSchoolGuideEvents());
      addTearDown(service.dispose);
      service.attach(client);
      await service.refresh();
      expect(service.available, isFalse);
      expect(service.reminders, isEmpty);
    });

    test('sets and clears a reminder on the server', () async {
      final calls = <String>[];
      final client = testJellyfinClient(
        handler: (request) async {
          calls.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/PlezyFin/OldSchool/Reminders')) {
            return jsonResponse({'Items': <Object?>[]});
          }
          if (request.method == 'POST' && path.endsWith('/PlezyFin/OldSchool/Reminders')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['ChannelId'], 'films');
            expect(body['ItemId'], 'blade-runner');
            expect(DateTime.parse(body['Start'] as String), start);
            return jsonResponse(dto('r1'));
          }
          if (request.method == 'DELETE' && path.endsWith('/PlezyFin/OldSchool/Reminders/r1')) {
            return http.Response('', 204);
          }
          return http.Response('{}', 404);
        },
      );
      final service = OldSchoolReminderService(events: OldSchoolGuideEvents());
      addTearDown(service.dispose);
      service.attach(client);
      await service.refresh();
      expect(service.available, isTrue);

      expect(await service.setReminder('films', entry(), on: true), isTrue);
      expect(service.reminderFor('films', entry())?.id, 'r1');

      expect(await service.setReminder('films', entry(), on: false), isTrue);
      expect(service.reminderFor('films', entry()), isNull);
      expect(calls.where((c) => c.startsWith('DELETE')), hasLength(1));
    });

    test('raises the notice a minute before the start, one at a time', () {
      fakeAsync((async) {
        final now = DateTime.utc(2026, 11, 1, 20, 55);
        final service = OldSchoolReminderService(events: OldSchoolGuideEvents(), clock: () => now.add(async.elapsed));
        final second = start.add(const Duration(minutes: 1));
        service.debugSetReminders([
          OldSchoolReminder.fromJson(dto('r1'))!,
          OldSchoolReminder.fromJson(dto('r2', at: second))!,
        ]);

        async.elapse(const Duration(minutes: 3, seconds: 59));
        expect(service.due.value, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(service.due.value?.id, 'r1');

        // The second waits until the first is answered.
        async.elapse(const Duration(minutes: 1));
        expect(service.due.value?.id, 'r1');
        service.finish(service.due.value!);
        expect(service.due.value?.id, 'r2');
        service.finish(service.due.value!);
        expect(service.due.value, isNull);
        expect(service.reminders, isEmpty);
        service.dispose();
      });
    });

    test('a reminder removed elsewhere takes its notice down', () async {
      var items = <Object?>[dto('r1', at: DateTime.now().toUtc().add(const Duration(seconds: 30)))];
      final client = testJellyfinClient(
        handler: (request) async {
          if (request.url.path.endsWith('/PlezyFin/OldSchool/Reminders')) return jsonResponse({'Items': items});
          return http.Response('{}', 404);
        },
      );
      final service = OldSchoolReminderService(events: OldSchoolGuideEvents());
      addTearDown(service.dispose);
      service.attach(client);
      await service.refresh();
      expect(service.due.value?.id, 'r1');

      items = [];
      await service.refresh();
      expect(service.due.value, isNull);
    });
  });
}
