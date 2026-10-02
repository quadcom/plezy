import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/update_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  const lastCheckKey = 'update_last_check_time';

  setUp(resetSharedPreferencesForTest);
  PackageInfo.setMockInitialValues(
    appName: 'Plezy',
    packageName: 'com.plezy.test',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  test('malformed cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, 'not-an-instant');

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('future cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, DateTime.now().add(const Duration(days: 30)).toIso8601String());

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('recent valid cooldown state suppresses a duplicate check and remains stored', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final recent = DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String();
    await prefs.setString(lastCheckKey, recent);

    expect(await UpdateService.shouldCheckForUpdates(), isFalse);
    expect(prefs.getString(lastCheckKey), recent);
  });

  test('old valid cooldown state permits a new check', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final old = DateTime.now().subtract(const Duration(days: 2)).toIso8601String();
    await prefs.setString(lastCheckKey, old);

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), old);
  });

  final failedResponses = <String, Future<http.Response> Function()>{
    'timeout': () async => throw TimeoutException('request timed out'),
    'non-200 response': () async => http.Response('unavailable', 503),
    'parse failure': () async => http.Response('not-json', 200, headers: {'content-type': 'application/json'}),
  };

  for (final failure in failedResponses.entries) {
    test('startup ${failure.key} records cooldown before request and manual check bypasses it', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final cooldownAtRequest = <String?>[];
      var requestCount = 0;
      final client = MediaServerHttpClient(
        client: MockClient((_) async {
          requestCount++;
          cooldownAtRequest.add(prefs.getString(lastCheckKey));
          return failure.value();
        }),
      );
      addTearDown(client.close);

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1);
      expect(cooldownAtRequest.single, isNotNull);
      final recordedCooldown = prefs.getString(lastCheckKey);
      expect(recordedCooldown, cooldownAtRequest.single);
      expect(DateTime.now().difference(DateTime.parse(recordedCooldown!)), lessThan(const Duration(minutes: 1)));

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1, reason: 'a simulated next launch must honor the failed attempt cooldown');

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client), isNull);
      expect(requestCount, 2, reason: 'an explicit manual check must bypass a recent startup cooldown');
      expect(
        prefs.getString(lastCheckKey),
        recordedCooldown,
        reason: 'manual checks must not rewrite startup cooldown',
      );
    });
  }

  test('checks the fork releases and returns the release APKs', () async {
    final requested = <Uri>[];
    final client = MediaServerHttpClient(
      client: MockClient((request) async {
        requested.add(request.url);
        return http.Response(
          jsonEncode({
            'tag_name': 'v2026.10.1',
            'html_url': 'https://github.com/quadcom/plezy/releases/tag/v2026.10.1',
            'name': 'Plezy 2026.10.1',
            'body': 'Based on Plezy 2.21.0',
            'published_at': '2026-10-02T12:00:00Z',
            'assets': [
              {
                'name': 'plezy-2026.10.1-arm64-v8a.apk',
                'browser_download_url': 'https://example.test/a.apk',
                'size': 10,
              },
              {'name': 'broken'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    final info = await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client);

    expect(requested.single.path, '/repos/quadcom/plezy/releases/latest');
    expect(info?['latestVersion'], '2026.10.1');
    expect(info?['assets'], [
      {'name': 'plezy-2026.10.1-arm64-v8a.apk', 'url': 'https://example.test/a.apk', 'size': 10},
    ]);
  });

  test('date-based fork versions compare by year, month, then release', () {
    expect(UpdateService.debugIsNewerVersion('2026.10.1', '2.21.0'), isTrue);
    expect(UpdateService.debugIsNewerVersion('2026.10.2', '2026.10.1'), isTrue);
    expect(UpdateService.debugIsNewerVersion('2026.11.1', '2026.10.9'), isTrue);
    expect(UpdateService.debugIsNewerVersion('2026.10.1', '2026.10.1'), isFalse);
    expect(UpdateService.debugIsNewerVersion('2026.9.5', '2026.10.1'), isFalse);
  });

  test('release assets without a name or download URL are dropped', () {
    expect(UpdateService.releaseAssets(null), isEmpty);
    expect(
      UpdateService.releaseAssets([
        {'name': 'x.apk', 'browser_download_url': 'https://example.test/x.apk'},
        {'browser_download_url': 'https://example.test/y.apk'},
        'junk',
      ]),
      [
        {'name': 'x.apk', 'url': 'https://example.test/x.apk', 'size': null},
      ],
    );
  });
}
