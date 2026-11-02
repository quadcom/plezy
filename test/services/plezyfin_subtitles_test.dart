import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/plezyfin_subtitles.dart';
import 'package:plezy/widgets/video_controls/helpers/plezyfin_subtitle_finder.dart';
import 'package:plezy/widgets/video_controls/models/subtitle_search_source.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

// local/plans/subtitle-search-plezyfin.md, PlezyFin PLAN_PFN_103. The JSON
// below is the live server's own answers (2026-11-01), ids shortened.
void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  const pausedSearch = {
    'Ok': false,
    'Message':
        'No subtitles found. opensubtitles.com is paused for about 4 hours (daily limit). '
        'yifysubtitles is paused for about 5 minutes.',
    'Results': <Object?>[],
    'Unavailable': [
      {'Name': 'opensubtitlescom', 'Status': 'DownloadLimitExceeded', 'Retry': 'in 4 hours'},
      {'Name': 'yifysubtitles', 'Status': 'SSLError', 'Retry': 'in 5 minutes'},
    ],
  };

  const foundSearch = {
    'Ok': true,
    'Message': '',
    'Results': [
      {
        'Id': 'r1',
        'Provider': 'opensubtitlescom',
        'Release': 'Patience.S02E05.1080p.WEB',
        'Score': 96,
        'Language': 'en',
        'Forced': true,
        'HearingImpaired': false,
        'Format': 'srt',
        'Uploader': 'kitkat',
      },
      {
        'Id': 'r2',
        'Provider': 'embeddedsubtitles',
        'Release': 'Patience (2025) - S02E05.en.srt',
        'Score': 100,
        'Language': 'en',
        'Forced': false,
        'HearingImpaired': true,
        'Format': 'srt',
        'Uploader': '',
      },
    ],
    'Unavailable': [
      {'Name': 'opensubtitlescom', 'Status': 'DownloadLimitExceeded', 'Retry': 'in 4 hours'},
    ],
  };

  group('reading the answers', () {
    test('status', () {
      final status = PlezyFinSubtitleStatus.fromJson({
        'Enabled': true,
        'Allowed': false,
        'Providers': [
          {'Name': 'embeddedsubtitles', 'Status': 'Good', 'Retry': '-'},
          {'Name': 'opensubtitlescom', 'Status': 'DownloadLimitExceeded', 'Retry': 'in 4 hours'},
        ],
      })!;
      expect(status.enabled, isTrue);
      expect(status.allowed, isFalse);
      expect(status.searchAvailable, isFalse);
      expect(status.providers.first.retry, isNull, reason: '"-" means not waiting');
      expect(status.providers.last.summary, 'opensubtitlescom: DownloadLimitExceeded, in 4 hours');
    });

    test('a search that found nothing because providers are paused', () {
      final search = PlezyFinSubtitleSearch.fromJson(pausedSearch);
      expect(search.ok, isFalse);
      expect(search.message, startsWith('No subtitles found. opensubtitles.com is paused'));
      expect(search.results, isEmpty);
      expect(search.unavailable.map((p) => p.summary), [
        'opensubtitlescom: DownloadLimitExceeded, in 4 hours',
        'yifysubtitles: SSLError, in 5 minutes',
      ]);
    });

    test('results, and the plan spelling Provider for an unavailable entry', () {
      final search = PlezyFinSubtitleSearch.fromJson({
        ...foundSearch,
        'Unavailable': [
          {'Provider': 'opensubtitlescom', 'Status': 'DownloadLimitExceeded', 'Retry': 'in 4 hours'},
        ],
      });
      expect(search.ok, isTrue);
      expect(search.results.map((r) => r.id), ['r1', 'r2']);
      final first = search.results.first;
      expect(first.release, 'Patience.S02E05.1080p.WEB');
      expect(first.score, 96);
      expect(first.forced, isTrue);
      expect(first.uploader, 'kitkat');
      expect(search.results.last.uploader, isNull, reason: 'an empty uploader is no uploader');
      expect(search.unavailable.single.name, 'opensubtitlescom');
    });

    test('download answers', () {
      final saved = PlezyFinSubtitleDownload.fromJson({'Ok': true, 'Message': ''});
      expect(saved.ok, isTrue);
      final refused = PlezyFinSubtitleDownload.fromJson({
        'Ok': false,
        'Message': 'That result is older than 30 minutes. Search again.',
      });
      expect(refused.ok, isFalse);
      expect(refused.message, 'That result is older than 30 minutes. Search again.');
      final bare = PlezyFinSubtitleDownload.fromJson('Send the id of the film or episode.', statusCode: 400);
      expect(bare.ok, isFalse);
      expect(bare.message, 'Send the id of the film or episode.');
    });
  });

  group('status gating', () {
    Future<bool> offeredFor(http.Response Function() answer) async {
      final client = testJellyfinClient(handler: (_) async => answer());
      addTearDown(client.close);
      await client.subtitleSearchStatus();
      return subtitleSearchOffered(client);
    }

    test('no route (404) hides the button', () async {
      expect(await offeredFor(() => http.Response('', 404)), isFalse);
    });

    test('Enabled false hides it', () async {
      expect(await offeredFor(() => jsonResponse({'Enabled': false, 'Allowed': true})), isFalse);
    });

    test('Allowed false hides it', () async {
      expect(await offeredFor(() => jsonResponse({'Enabled': true, 'Allowed': false})), isFalse);
    });

    test('Enabled and Allowed show it', () async {
      expect(await offeredFor(() => jsonResponse({'Enabled': true, 'Allowed': true})), isTrue);
    });

    test('hidden until the status is known, which is read once and kept', () async {
      final calls = <String>[];
      final client = testJellyfinClient(
        handler: (request) async {
          calls.add(request.url.path);
          return jsonResponse({'Enabled': true, 'Allowed': true});
        },
      );
      addTearDown(client.close);

      var asked = 0;
      expect(subtitleSearchOffered(client, loadStatus: (_) => asked++), isFalse);
      expect(asked, 1);

      final pending = client.subtitleSearchStatus();
      expect(subtitleSearchOffered(client, loadStatus: (_) => asked++), isFalse);
      expect(asked, 1, reason: 'a read in flight is not asked for again');

      await Future.wait([pending, client.subtitleSearchStatus()]);
      await client.subtitleSearchStatus();
      expect(calls, ['/PlezyFin/Subtitles/Status'], reason: 'one request per connection');

      expect(subtitleSearchOffered(client, loadStatus: (_) => asked++), isTrue);
      expect(asked, 1);
      expect(subtitleSearchOffered(client, offlineOrLive: true), isFalse);
    });

    test('a failed read hides it without asking again straight away', () async {
      var calls = 0;
      final client = testJellyfinClient(
        handler: (_) async {
          calls++;
          return http.Response('boom', 500);
        },
      );
      addTearDown(client.close);
      await client.subtitleSearchStatus();
      await client.subtitleSearchStatus();
      expect(calls, 1);
      expect(client.cachedSubtitleSearchAvailable, isFalse);
    });

    test('other servers keep their capability', () {
      expect(subtitleSearchOffered(_CapabilityClient(ServerCapabilities.plex)), isTrue);
      expect(subtitleSearchOffered(_CapabilityClient(ServerCapabilities.jellyfin)), isFalse);
      expect(subtitleSearchOffered(null), isFalse);
    });
  });

  group('PlezyFin source', () {
    test('search asks for the playing version, forced only when the filter is on', () async {
      final queries = <Map<String, String>>[];
      final client = testJellyfinClient(
        handler: (request) async {
          expect(request.url.path, '/PlezyFin/Subtitles/Search');
          queries.add(request.url.queryParameters);
          return jsonResponse(foundSearch);
        },
      );
      addTearDown(client.close);
      final source = PlezyFinSubtitleSearchSource(client, 'item-1', mediaSourceId: 'src-2');

      final page = await source.search(language: 'en');
      await source.search(language: 'fr', forcedOnly: true);

      expect(queries.first, {'itemId': 'item-1', 'mediaSourceId': 'src-2', 'language': 'en'});
      expect(queries.last, {'itemId': 'item-1', 'mediaSourceId': 'src-2', 'language': 'fr', 'forced': 'true'});

      expect(page.message, isNull);
      expect(page.hits.first.title, 'Patience.S02E05.1080p.WEB');
      expect(page.hits.first.subtitle, 'opensubtitlescom · kitkat');
      expect(page.hits.first.score, 96);
      expect(page.hits.first.forced, isTrue);
      expect(page.hits.last.subtitle, 'embeddedsubtitles');
      expect(page.hits.last.hearingImpaired, isTrue);
      expect(page.notes, ['opensubtitlescom: DownloadLimitExceeded, in 4 hours']);
    });

    test('Ok false shows the server message as is, with the paused providers under it', () async {
      final client = testJellyfinClient(handler: (_) async => jsonResponse(pausedSearch));
      addTearDown(client.close);
      final page = await PlezyFinSubtitleSearchSource(client, 'item-1').search(language: 'en');
      expect(page.hits, isEmpty);
      expect(page.message, pausedSearch['Message']);
      expect(page.notes, hasLength(2));
    });

    test('a saved download gives what was saved and the files there before', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = testJellyfinClient(
        handler: (request) async {
          if (request.method == 'POST') {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return jsonResponse({'Ok': true, 'Message': ''});
          }
          return jsonResponse(_item(externals: [_external(0, '/m/Film.en.srt')]));
        },
      );
      addTearDown(client.close);
      final source = PlezyFinSubtitleSearchSource(client, 'item-1', mediaSourceId: 'src-1');
      final hit = (await _hitsFrom(foundSearch)).first;

      final result = await source.download(hit, language: 'en');

      expect(bodies.single, {'Id': 'r1', 'ItemId': 'item-1'});
      expect(result.ok, isTrue);
      expect(result.hint!.forced, isTrue);
      expect(result.hint!.languageCode, 'en');
      expect(result.hint!.filesBefore!.single.path, '/m/Film.en.srt');
    });

    test('a refused download says why', () async {
      var answer = jsonResponse({'Ok': false, 'Message': 'opensubtitles.com download limit reached for today.'});
      final client = testJellyfinClient(
        handler: (request) async => request.method == 'POST' ? answer : jsonResponse(_item()),
      );
      addTearDown(client.close);
      final source = PlezyFinSubtitleSearchSource(client, 'item-1');
      final hit = (await _hitsFrom(foundSearch)).first;

      var result = await source.download(hit, language: 'en');
      expect(result.ok, isFalse);
      expect(result.message, 'opensubtitles.com download limit reached for today.');

      answer = http.Response('', 403);
      result = await source.download(hit, language: 'en');
      expect(result.ok, isFalse);
      expect(result.message, t.videoControls.subtitleDownloadNotAllowed);
    });

    test('the file listing reads the version asked for', () async {
      final client = testJellyfinClient(
        handler: (_) async => jsonResponse({
          'Id': 'item-1',
          'Name': 'Film',
          'Type': 'Movie',
          'MediaSources': [
            _source('src-1', [_external(0, '/m/A.en.srt')]),
            _source('src-2', [_external(0, '/m/B.en.forced.srt', forced: true), _external(1, '/m/B.en.srt')]),
          ],
        }),
      );
      addTearDown(client.close);
      final files = await client.fetchExternalSubtitleFiles('item-1', mediaSourceId: 'src-2');
      expect(files!.map((f) => f.path), ['/m/B.en.forced.srt', '/m/B.en.srt']);
      expect(files.first.forced, isTrue);
      expect(await client.fetchExternalSubtitleFiles('item-1', mediaSourceId: 'gone'), isNull);
    });
  });

  group('finding the downloaded file', () {
    const forcedEn = DownloadedSubtitleHint(languageCode: 'en', forced: true, format: 'srt');

    test('a new file is the one not there before, though every index shifted', () {
      final before = [const PlezyFinExternalSubtitle(index: 0, path: '/m/Film.en.srt', language: 'eng')];
      final after = [
        const PlezyFinExternalSubtitle(index: 0, path: '/m/Film.en.forced.srt', language: 'eng', forced: true),
        const PlezyFinExternalSubtitle(index: 1, path: '/m/Film.en.srt', language: 'eng'),
      ];
      final hint = DownloadedSubtitleHint(languageCode: 'en', forced: true, format: 'srt', filesBefore: before);
      expect(findDownloadedPlezyFinSubtitle(before, hint: hint), isNull, reason: 'not refreshed yet');
      expect(findDownloadedPlezyFinSubtitle(after, hint: hint), 0);
    });

    test('an overwritten file is found at once under its Bazarr name', () {
      final files = [
        const PlezyFinExternalSubtitle(index: 0, path: '/m/Film.en.forced.srt', language: 'eng', forced: true),
        const PlezyFinExternalSubtitle(index: 1, path: '/m/Film.en.srt', language: 'eng'),
      ];
      final hint = DownloadedSubtitleHint(languageCode: 'en', forced: true, format: 'srt', filesBefore: files);
      expect(findDownloadedPlezyFinSubtitle(files, hint: hint), 0);
    });

    test('without paths, a file more than before that matches', () {
      final before = [const PlezyFinExternalSubtitle(index: 0, language: 'eng')];
      final after = [
        const PlezyFinExternalSubtitle(index: 0, language: 'eng'),
        const PlezyFinExternalSubtitle(index: 1, language: 'eng', forced: true),
      ];
      final hint = DownloadedSubtitleHint(languageCode: 'en', forced: true, filesBefore: before);
      expect(findDownloadedPlezyFinSubtitle(before, hint: hint), isNull);
      expect(findDownloadedPlezyFinSubtitle(after, hint: hint), 1);
    });

    test('another language or a forced mismatch is never taken', () {
      final files = [
        const PlezyFinExternalSubtitle(index: 0, path: '/m/Film.fr.forced.srt', language: 'fre', forced: true),
        const PlezyFinExternalSubtitle(index: 1, path: '/m/Film.en.srt', language: 'eng'),
      ];
      expect(findDownloadedPlezyFinSubtitle(files, hint: forcedEn, lastTry: true), isNull);
    });

    test('polls every 2 s, one read at a time, and stops when found', () {
      fakeAsync((async) {
        var reads = 0;
        var inFlight = 0;
        var maxInFlight = 0;
        PlezyFinSubtitlePollResult? result;
        final hint = DownloadedSubtitleHint(
          languageCode: 'en',
          forced: true,
          format: 'srt',
          filesBefore: const [PlezyFinExternalSubtitle(index: 0, path: '/m/Film.en.srt', language: 'eng')],
        );
        pollForDownloadedPlezyFinSubtitle(
          fetch: () async {
            reads++;
            inFlight++;
            if (inFlight > maxInFlight) maxInFlight = inFlight;
            await Future<void>.delayed(const Duration(milliseconds: 500));
            inFlight--;
            return [
              if (reads >= 3)
                const PlezyFinExternalSubtitle(index: 0, path: '/m/Film.en.forced.srt', language: 'eng', forced: true),
              PlezyFinExternalSubtitle(index: reads >= 3 ? 1 : 0, path: '/m/Film.en.srt', language: 'eng'),
            ];
          },
          hint: hint,
          isCurrent: () => true,
        ).then((value) => result = value);

        async.elapse(const Duration(seconds: 1));
        expect(reads, 0, reason: 'the first read waits 2 s');
        async.elapse(const Duration(seconds: 30));
        expect(result, (index: 0, superseded: false));
        expect(reads, 3);
        expect(maxInFlight, 1);
      });
    });

    test('gives up after about 15 s and when the player moves on', () {
      fakeAsync((async) {
        var reads = 0;
        PlezyFinSubtitlePollResult? timedOut;
        pollForDownloadedPlezyFinSubtitle(
          fetch: () async {
            reads++;
            return const <PlezyFinExternalSubtitle>[];
          },
          hint: forcedEn,
          isCurrent: () => true,
        ).then((value) => timedOut = value);
        async.elapse(const Duration(seconds: 60));
        expect(timedOut, (index: null, superseded: false));
        expect(reads, 7);

        var current = true;
        PlezyFinSubtitlePollResult? superseded;
        pollForDownloadedPlezyFinSubtitle(
          fetch: () async => const <PlezyFinExternalSubtitle>[],
          hint: forcedEn,
          isCurrent: () => current,
        ).then((value) => superseded = value);
        async.elapse(const Duration(seconds: 3));
        current = false;
        async.elapse(const Duration(seconds: 3));
        expect(superseded, (index: null, superseded: true));
      });
    });
  });
}

class _CapabilityClient implements MediaServerClient {
  _CapabilityClient(this.capabilities);

  @override
  final ServerCapabilities capabilities;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<List<SubtitleSearchHit>> _hitsFrom(Map<String, Object?> answer) async {
  final client = testJellyfinClient(handler: (_) async => jsonResponse(answer));
  addTearDown(client.close);
  return (await PlezyFinSubtitleSearchSource(client, 'item-1').search(language: 'en')).hits;
}

Map<String, Object?> _external(int index, String path, {bool forced = false}) => {
  'Type': 'Subtitle',
  'Index': index,
  'IsExternal': true,
  'IsForced': forced,
  'Language': 'eng',
  'Codec': 'srt',
  'Path': path,
};

Map<String, Object?> _source(String id, List<Map<String, Object?>> externals) => {
  'Id': id,
  'Container': 'mkv',
  'MediaStreams': [
    ...externals,
    {'Type': 'Video', 'Index': externals.length, 'Codec': 'hevc'},
  ],
};

Map<String, Object?> _item({List<Map<String, Object?>> externals = const []}) => {
  'Id': 'item-1',
  'Name': 'Film',
  'Type': 'Movie',
  'MediaSources': [_source('src-1', externals)],
};
