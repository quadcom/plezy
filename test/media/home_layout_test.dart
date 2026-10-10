import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/home_layout.dart';
import 'package:plezy/media/library_layout.dart';

void main() {
  test('missing sections follow in the built-in order; repeats and unknown ids are not shown', () {
    final home = HomeLayout.fromJson({
      'order': ['libraries', 'later', 'resume', 'libraries'],
      'off': ['nextup'],
    });
    expect(home.sections, ['libraries', 'resume', 'hero', 'nextup']);
    expect(home.isOn('nextup'), isFalse);
    expect(home.isOn('hero'), isTrue);
  });

  test('an empty home is everything on in the built-in order', () {
    final home = HomeLayout.fromJson(const {});
    expect(home.sections, HomeLayout.builtInOrder);
    expect(home.off, isEmpty);
  });

  test('junk card values drop; unknown keys and ids survive a round trip', () {
    final home = HomeLayout.fromJson({
      'order': ['resume', 'later'],
      'off': ['later'],
      'cards': {'resume': 'thumb', 'nextup': 'wide', 'own/movies': 'poster'},
      'extra': [1, 2],
    });
    expect(home.cards, {'resume': HomeCardStyle.thumb, 'own/movies': HomeCardStyle.poster});
    expect(home.toJson(), {
      'extra': [1, 2],
      'order': ['resume', 'later'],
      'off': ['later'],
      'cards': {'resume': 'thumb', 'own/movies': 'poster'},
    });
  });

  test('reordering keeps unknown ids in their slots', () {
    const home = HomeLayout(order: ['hero', 'later', 'resume', 'nextup', 'libraries']);
    expect(home.withSections(['libraries', 'hero', 'resume', 'nextup']).order, [
      'libraries',
      'later',
      'hero',
      'resume',
      'nextup',
    ]);
  });

  test('switching and card choices', () {
    final home = HomeLayout.standard
        .withSection('hero', on: false)
        .withSection('hero', on: false)
        .withCard('resume', HomeCardStyle.poster)
        .withCard('nextup', HomeCardStyle.thumb)
        .withCard('resume', null);
    expect(home.off, ['hero']);
    expect(home.cards, {'nextup': HomeCardStyle.thumb});
    expect(home.withSection('hero', on: true).off, isEmpty);
  });

  test('the layout record keeps home and fields it does not know through every change', () {
    final layout = LibraryLayout.fromJson({
      'v': 1,
      'rev': 2,
      'order': ['own/a'],
      'home': {
        'order': ['nextup', 'resume'],
        'off': <String>[],
      },
      'future': 'kept',
    });
    expect(layout.home!.order, ['nextup', 'resume']);

    final managed = layout.withManaged(
      librariesByServer: {
        'own': ['a', 'b'],
      },
      managedOrder: ['own/b', 'own/a'],
      managedState: const {},
      now: DateTime.utc(2026, 10, 9),
    );
    expect(managed.toJson()['future'], 'kept');
    expect(managed.home, layout.home);

    final rehomed = managed.withHome(const HomeLayout(off: ['hero']), now: DateTime.utc(2026, 10, 9));
    final json = LibraryLayout.tryParse(rehomed.encode())!.toJson();
    expect(json['rev'], 4);
    expect(json['order'], ['own/b', 'own/a']);
    expect(json['future'], 'kept');
    expect((json['home'] as Map)['off'], ['hero']);
  });

  group('home rows', () {
    test('read: repeats drop, a key may be in both lists, junk is ignored', () {
      final home = HomeLayout.fromJson({
        'rows': {
          'order': ['own/a', 'own/b', 'own/a', 3, ''],
          'off': ['own/b', 'own/b'],
        },
      });
      expect(home.rows, const HomeRows(order: ['own/a', 'own/b'], off: ['own/b']));
      expect(home.toJson()['rows'], {
        'order': ['own/a', 'own/b'],
        'off': ['own/b'],
      });
      expect(HomeLayout.fromJson(const {}).rows, isNull);
      expect(HomeLayout.fromJson(const {}).toJson().containsKey('rows'), isFalse);
    });

    test('arrange puts listed keys first in their order, the rest after in the order given', () {
      const rows = HomeRows(order: ['own/c', 'gone/x', 'own/a']);
      expect(rows.arrange(['own/a', 'own/b', 'own/c', 'own/d']), ['own/c', 'own/a', 'own/b', 'own/d']);
    });

    test('place keeps keys it does not manage in their slots and switches', () {
      const rows = HomeRows(order: ['own/a', 'own/hidden', 'own/b', 'plex/x'], off: ['own/hidden', 'own/b']);
      final next = rows.place(
        managed: {'own/a', 'own/b', 'own/new'},
        ordered: ['own/b', 'own/a', 'own/new'],
        offKeys: {'own/a'},
      );
      expect(next.order, ['own/b', 'own/hidden', 'own/a', 'plex/x', 'own/new']);
      expect(next.off, ['own/hidden', 'own/a']);
    });

    test('the other home fields keep the rows', () {
      final home = const HomeLayout().withRows(const HomeRows(order: ['own/a'], off: ['own/a']));
      expect(home.withSection(HomeLayout.hero, on: false).rows, home.rows);
      expect(home.withCard('own/a', HomeCardStyle.thumb).rows, home.rows);
      expect(home.withSections(HomeLayout.builtInOrder).rows, home.rows);
    });
  });

  test('season posters are a card style of their own', () {
    final home = HomeLayout.fromJson({
      'cards': {'own/tv': 'season', 'own/movies': 'poster'},
    });
    expect(home.cards, {'own/tv': HomeCardStyle.season, 'own/movies': HomeCardStyle.poster});
    expect((home.toJson()['cards'] as Map)['own/tv'], 'season');
  });
}
