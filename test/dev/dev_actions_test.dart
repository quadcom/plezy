import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/dev/dev_actions.dart';
import 'package:plezy/dev/startup_timeline.dart';

/// The action list behind the Developer tools page and the dev channel's
/// actions.list / actions.run (local/plans/dev-tools.md).
void main() {
  tearDown(DevActions.debugReset);

  test('every action has a unique name, a known group and a description', () {
    final names = DevActions.all.map((a) => a.name).toList();
    expect(names.toSet(), hasLength(names.length));
    for (final action in DevActions.all) {
      expect(DevActions.groups, contains(action.group), reason: action.name);
      expect(action.description, isNotEmpty, reason: action.name);
      expect(action.toJson()['inputs'], isA<List<dynamic>>());
    }
    for (final group in DevActions.groups) {
      expect(DevActions.all.where((a) => a.group == group), isNotEmpty, reason: group);
    }
  });

  test('look actions change nothing; navigate and player commands are marked as changes', () {
    for (final action in DevActions.all.where((a) => a.group == 'look')) {
      expect(action.changes, isFalse, reason: action.name);
    }
    for (final name in ['ui.key', 'nav.back', 'nav.open', 'player.play', 'player.stop', 'cache.clear_images']) {
      expect(DevActions.byName(name)!.changes, isTrue, reason: name);
    }
  });

  group('validate', () {
    final search = DevActions.byName('media.search')!;
    final play = DevActions.byName('player.play')!;
    final seek = DevActions.byName('player.seek')!;

    test('needs required inputs', () {
      expect(() => DevActions.validate(search, {}), throwsArgumentError);
    });

    test('refuses inputs the action does not have', () {
      expect(() => DevActions.validate(search, {'query': 'x', 'colour': 'red'}), throwsArgumentError);
    });

    test('turns text into the declared types', () {
      expect(DevActions.validate(search, {'query': 'Alien', 'limit': '5'}), {'query': 'Alien', 'limit': 5});
      expect(DevActions.validate(seek, {'by': '-10'}), {'by': -10.0});
      expect(() => DevActions.validate(seek, {'by': 'soon'}), throwsArgumentError);
    });

    test('checks choices', () {
      expect(DevActions.validate(play, {'itemId': 'a', 'start': 'beginning'}), {'itemId': 'a', 'start': 'beginning'});
      expect(() => DevActions.validate(play, {'itemId': 'a', 'start': 'middle'}), throwsArgumentError);
    });
  });

  test('keyFor knows remote keys, letters and digits', () {
    expect(DevActions.keyFor('Up'), LogicalKeyboardKey.arrowUp);
    expect(DevActions.keyFor('back'), LogicalKeyboardKey.goBack);
    expect(DevActions.keyFor('select'), LogicalKeyboardKey.select);
    expect(DevActions.keyFor('h'), LogicalKeyboardKey.keyH);
    expect(DevActions.keyFor('7'), LogicalKeyboardKey.digit7);
    expect(() => DevActions.keyFor('hyperjump'), throwsArgumentError);
  });

  test('run refuses while developer mode is off', () async {
    await expectLater(DevActions.run('app.status', {}), throwsStateError);
  });

  test('agent refuses setting changes outside this device', () async {
    await expectLater(
      DevActions.agent('settings.set', {
        'key': 'x',
        'value': 1,
        'scope': {'type': 'server', 'serverId': 's'},
      }),
      throwsStateError,
    );
  });

  group('startup timeline', () {
    setUp(StartupTimeline.debugReset);
    tearDown(StartupTimeline.debugReset);

    test('records marks and timed steps in order', () async {
      StartupTimeline.start();
      StartupTimeline.mark('first frame');
      final value = await StartupTimeline.time('task Gamepad', () async => 42);
      expect(value, 42);
      final json = StartupTimeline.toJson();
      final entries = json['entries'] as List;
      expect(entries.map((e) => (e as Map)['name']), ['first frame', 'task Gamepad']);
      expect((entries.last as Map)['tookMs'], isA<int>());
      expect(json['startedAt'], isNotNull);
    });

    test('a failing step is still recorded', () async {
      StartupTimeline.start();
      await expectLater(StartupTimeline.time('phase database', () async => throw StateError('x')), throwsStateError);
      expect((StartupTimeline.toJson()['entries'] as List).single, containsPair('name', 'phase database'));
    });
  });
}
