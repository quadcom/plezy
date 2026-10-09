import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_layout.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_library.dart';

MediaLibrary _jf(String serverId, String id) =>
    MediaLibrary(id: id, backend: MediaBackend.jellyfin, title: id, serverId: serverId);

MediaLibrary _plex(String serverId, String id) =>
    MediaLibrary(id: id, backend: MediaBackend.plex, title: id, serverId: serverId);

void main() {
  test('keys: Jellyfin ids lose dashes and case, Plex keeps its own', () {
    expect(libraryLayoutKey(_jf('793A-A546', 'F137-A2DD')), '793aa546/f137a2dd');
    expect(libraryLayoutKey(_plex('AbC123', '1')), 'AbC123/1');
  });

  test('the sample record from PlezyFin round-trips', () {
    const raw =
        '{"v":1,"rev":3,"updated":"2026-10-09T20:15:00Z","order":["own/a","plex/1","own/b"],'
        '"state":{"own/a":"shown","plex/1":"folded","own/c":"folded"},'
        '"known":{"own":["a","b","c"],"plex":["1"]}}';
    final layout = LibraryLayout.tryParse(raw)!;
    expect(layout.rev, 3);
    expect(layout.order, ['own/a', 'plex/1', 'own/b']);
    expect(layout.state['plex/1'], LibraryState.folded);
    expect(LibraryLayout.tryParse(layout.encode())!.toJson(), layout.toJson());
  });

  test('titles: blank ones drop, long ones are cut, the record wins over the default', () {
    final layout = LibraryLayout.fromJson({
      'titles': {'own/a': '  Fresh  ', 'own/b': '   ', 'own/c': 'x' * 100},
    });
    expect(layout.titles, {'own/a': 'Fresh', 'own/c': 'x' * libraryRowTitleMaxLength});
    const defaults = LibraryLayout(titles: {'own/a': 'Default A', 'own/d': 'Default D'});
    expect(layout.titleFor('own/a', defaults: defaults), 'Fresh');
    expect(layout.titleFor('own/d', defaults: defaults), 'Default D');
    expect(layout.titleFor('own/e', defaults: defaults), isNull);
    expect(LibraryLayout.tryParse(layout.encode())!.titles, layout.titles);
  });

  test('junk does not parse', () {
    expect(LibraryLayout.tryParse(null), isNull);
    expect(LibraryLayout.tryParse('not json'), isNull);
    expect(LibraryLayout.tryParse('[1]'), isNull);
  });

  group('states the record does not name', () {
    const layout = LibraryLayout(
      known: {
        'plex': ['1'],
      },
    );

    test('own server: shown', () {
      expect(layout.stateOf('own/new', ownServerId: 'own'), LibraryState.shown);
    });

    test('another server: folded until known, then shown', () {
      expect(layout.stateOf('plex/2', ownServerId: 'own'), LibraryState.folded);
      expect(layout.stateOf('plex/1', ownServerId: 'own'), LibraryState.shown);
    });

    test('no PlezyFin account: shown, as Plezy always did', () {
      expect(layout.stateOf('plex/2'), LibraryState.shown);
    });
  });

  test('arrange puts the ordered keys first and new ones after, in the order given', () {
    const layout = LibraryLayout(order: ['own/b', 'gone/x', 'own/a']);
    final arranged = layout.arrange([_jf('own', 'a'), _jf('own', 'c'), _jf('own', 'b')], ownServerId: 'own');
    expect(arranged.order, ['own/b', 'own/a', 'own/c']);
  });

  test('writing keeps other servers in their slots and swaps only managed keys', () {
    const layout = LibraryLayout(
      rev: 4,
      order: ['own/a', 'friend/x', 'own/b', 'plex/1'],
      state: {'friend/x': LibraryState.off, 'own/a': LibraryState.shown},
      known: {
        'friend': ['x'],
        'own': ['a', 'b'],
      },
    );
    final next = layout.withManaged(
      librariesByServer: {
        'own': ['a', 'b', 'c'],
        'plex': ['1'],
      },
      managedOrder: ['plex/1', 'own/c', 'own/a', 'own/b'],
      managedState: {
        'plex/1': LibraryState.shown,
        'own/c': LibraryState.shown,
        'own/a': LibraryState.folded,
        'own/b': LibraryState.shown,
      },
      now: DateTime.utc(2026, 10, 9, 20),
    );
    expect(next.order, ['plex/1', 'friend/x', 'own/c', 'own/a', 'own/b']);
    expect(next.state['friend/x'], LibraryState.off);
    expect(next.state['own/a'], LibraryState.folded);
    expect(next.known, {
      'friend': ['x'],
      'own': ['a', 'b', 'c'],
      'plex': ['1'],
    });
    expect(next.rev, 5);
    expect(next.updated, startsWith('2026-10-09T20:00:00'));
  });

  test('seeding takes the own server from the default and keeps what the record says', () {
    const record = LibraryLayout(
      order: ['plex/1'],
      state: {'plex/1': LibraryState.folded, 'own/a': LibraryState.off},
      known: {
        'plex': ['1'],
      },
    );
    const defaults = LibraryLayout(
      order: ['own/a', 'own/b'],
      state: {'own/a': LibraryState.shown, 'own/b': LibraryState.folded, 'plex/9': LibraryState.off},
    );
    final seeded = record.seededFrom(defaults, ownServerId: 'own');
    expect(seeded.order, ['own/a', 'own/b', 'plex/1']);
    expect(seeded.state, {'own/b': LibraryState.folded, 'plex/1': LibraryState.folded, 'own/a': LibraryState.off});
  });

  test('knownDiffers spots a new library and a new server', () {
    const layout = LibraryLayout(
      known: {
        'own': ['a'],
      },
    );
    expect(
      layout.knownDiffers({
        'own': ['a'],
      }),
      isFalse,
    );
    expect(
      layout.knownDiffers({
        'own': ['a', 'b'],
      }),
      isTrue,
    );
    expect(
      layout.knownDiffers({
        'plex': ['1'],
      }),
      isTrue,
    );
  });
}
