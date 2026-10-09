import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_layout.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/storage_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  group('HiddenLibrariesProvider', () {
    test('device mode: folded and Not shown are kept apart, server-hidden reads as folded', () async {
      final p = HiddenLibrariesProvider();
      await p.ensureInitialized();
      await p.hideLibrary('srv-plex:1');

      var notified = 0;
      p.addListener(() => notified++);
      const libraries = [
        MediaLibrary(id: 'kids', backend: MediaBackend.jellyfin, title: 'Kids', hidden: true, serverId: 'srv-jf'),
        MediaLibrary(id: 'movies', backend: MediaBackend.jellyfin, title: 'Movies', serverId: 'srv-jf'),
        // Plex's own hidden flag is not a choice made in a client.
        MediaLibrary(id: '2', backend: MediaBackend.plex, title: 'Plex', hidden: true, serverId: 'srv-plex'),
      ];
      p.syncLibraries(libraries);
      final kids = libraries.first.globalKey;

      expect(p.stateOf(libraries.first), LibraryState.folded);
      expect(p.stateOf(libraries.last), LibraryState.shown);
      expect(p.foldedLibraryKeys, {kids});
      expect(p.hiddenLibraryKeys, {'srv-plex:1', kids});
      expect(p.offLibraryKeys, isEmpty);
      expect(notified, 1);

      p.syncLibraries(libraries);
      expect(notified, 1);

      await p.setLibraryState(libraries.last, LibraryState.off);
      expect(p.offLibraryKeys, {libraries.last.globalKey});
      expect(p.hiddenLibraryKeys, contains(libraries.last.globalKey));
      expect(p.foldedLibraryKeys, {kids});

      final again = HiddenLibrariesProvider();
      await again.ensureInitialized();
      again.syncLibraries(libraries);
      expect(again.stateOf(libraries.last), LibraryState.off);

      p.dispose();
      again.dispose();
    });

    test('starts uninitialized and exposes empty set', () async {
      final p = HiddenLibrariesProvider();
      expect(p.isInitialized, isFalse);
      expect(p.hiddenLibraryKeys, isEmpty);
      await p.ensureInitialized();
      expect(p.isInitialized, isTrue);
      expect(p.hiddenLibraryKeys, isEmpty);
      p.dispose();
    });

    test('hideLibrary persists key and notifies listeners', () async {
      final p = HiddenLibrariesProvider();
      await p.ensureInitialized();

      var notified = 0;
      p.addListener(() => notified++);

      await p.hideLibrary('lib-1');
      expect(p.isLibraryHidden('lib-1'), isTrue);
      expect(p.hiddenLibraryKeys, contains('lib-1'));
      expect(notified, 1);

      await p.hideLibrary('lib-1');
      expect(notified, 1);

      p.dispose();
    });

    test('persists across provider instances via SharedPreferences', () async {
      final first = HiddenLibrariesProvider();
      await first.ensureInitialized();
      await first.hideLibrary('lib-A');
      await first.hideLibrary('lib-B');
      first.dispose();

      // Reset only the cached singleton, NOT SharedPreferences — values survive.
      BaseSharedPreferencesService.resetForTesting();

      final second = HiddenLibrariesProvider();
      await second.ensureInitialized();
      expect(second.isLibraryHidden('lib-A'), isTrue);
      expect(second.isLibraryHidden('lib-B'), isTrue);
      expect(second.isLibraryHidden('lib-C'), isFalse);
      second.dispose();
    });

    test('unhideLibrary removes the key', () async {
      final p = HiddenLibrariesProvider();
      await p.ensureInitialized();
      await p.hideLibrary('lib-1');
      await p.hideLibrary('lib-2');

      await p.unhideLibrary('lib-1');
      expect(p.isLibraryHidden('lib-1'), isFalse);
      expect(p.isLibraryHidden('lib-2'), isTrue);

      await p.unhideLibrary('lib-3');
      expect(p.hiddenLibraryKeys, equals({'lib-2'}));

      p.dispose();
    });

    test('refresh re-reads from storage', () async {
      final p = HiddenLibrariesProvider();
      await p.ensureInitialized();
      expect(p.hiddenLibraryKeys, isEmpty);

      // Mutate underlying storage out-of-band, then refresh.
      final storage = await StorageService.getInstance();
      await storage.saveHiddenLibraries({'external-1', 'external-2'});

      await p.refresh();
      expect(p.hiddenLibraryKeys, equals({'external-1', 'external-2'}));

      p.dispose();
    });

    test('explicit profile id stays isolated when active profile changes', () async {
      final storage = await StorageService.getInstance();
      await storage.saveHiddenLibrariesForProfile('owner', {'srv:movies'});
      await storage.saveHiddenLibrariesForProfile('kids', {'srv:kids'});
      await storage.setActiveProfileId('owner');

      final ownerProvider = HiddenLibrariesProvider(storageService: storage, profileId: 'owner');
      final kidsProvider = HiddenLibrariesProvider(storageService: storage, profileId: 'kids');

      await storage.setActiveProfileId('kids');
      await ownerProvider.refresh();
      await kidsProvider.refresh();

      expect(ownerProvider.hiddenLibraryKeys, {'srv:movies'});
      expect(kidsProvider.hiddenLibraryKeys, {'srv:kids'});

      await ownerProvider.hideLibrary('srv:documentaries');

      expect(storage.getHiddenLibrariesForProfile('owner'), {'srv:movies', 'srv:documentaries'});
      expect(storage.getHiddenLibrariesForProfile('kids'), {'srv:kids'});
      expect(storage.getHiddenLibraries(), {'srv:kids'});

      ownerProvider.dispose();
      kidsProvider.dispose();
    });

    test('refresh marks provider initialized after deterministic reload', () async {
      final storage = await StorageService.getInstance();
      await storage.saveHiddenLibrariesForProfile('owner', {'srv:movies'});

      final p = HiddenLibrariesProvider(storageService: storage, profileId: 'owner');
      expect(p.isInitialized, isFalse);

      await p.refresh();

      expect(p.isInitialized, isTrue);
      expect(p.hiddenLibraryKeys, {'srv:movies'});

      p.dispose();
    });

    test('hiddenLibraryKeys returns an unmodifiable view', () async {
      final p = HiddenLibrariesProvider();
      await p.ensureInitialized();
      await p.hideLibrary('lib-1');

      expect(() => p.hiddenLibraryKeys.add('mutated'), throwsUnsupportedError);

      p.dispose();
    });

    test('safeNotifyListeners no-ops after dispose', () async {
      final p = HiddenLibrariesProvider();
      await p.ensureInitialized();
      p.dispose();
      await p.refresh();
    });
  });
}
