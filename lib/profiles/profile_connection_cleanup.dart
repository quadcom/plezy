import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../media/ids.dart';
import '../models/plex/plex_home_user.dart';
import '../services/multi_server_manager.dart';
import '../services/storage_service.dart';
import 'profile.dart';
import 'profile_connection_registry.dart';
import 'profile_merge.dart';
import 'profile_registry.dart';

/// Where the session should land after a profile or connection removal.
enum PostRemovalRoute { signedOut, staySignedIn }

/// Removal of profile↔connection join rows and everything they leave
/// unreferenced, bound to one set of registries. Every flow resolves the same
/// instances from the provider tree, so callers construct this once and call
/// through it.
class ProfileConnectionCleanup {
  ProfileConnectionCleanup({
    required this.profileConnections,
    required this.connections,
    required this.storage,
    this.serverManager,
  });

  final ProfileConnectionRegistry profileConnections;
  final ConnectionRegistry connections;
  final StorageService storage;
  final MultiServerManager? serverManager;

  Future<void> removeProfileConnection({required String profileId, required Connection connection}) async {
    final removedServerIds = _serverIdsForConnection(connection);
    await profileConnections.remove(profileId, connection.id);
    await _clearProfileServerPrefsNoLongerReferenced(
      profileId: profileId,
      removedServerIds: removedServerIds,
      clearEverywhereWhenUnreferenced: connection is JellyfinConnection,
    );

    if (connection is JellyfinConnection) {
      await _removeUnreferencedJellyfinConnection(connection);
    }
  }

  Future<void> removeAllProfileConnections(String profileId) async {
    final rows = await profileConnections.listForProfile(profileId);
    if (rows.isEmpty) return;

    final all = await connections.list();
    final byId = {for (final connection in all) connection.id: connection};
    for (final row in rows) {
      final connection = byId[row.connectionId];
      if (connection == null) {
        await profileConnections.remove(profileId, row.connectionId);
        continue;
      }
      await removeProfileConnection(profileId: profileId, connection: connection);
    }
  }

  /// In-session mirror of the boot guard (`main.dart`: "stored connections
  /// exist but no profiles resolved — returning to auth"): prune orphaned
  /// MediaBrowser connections, then decide whether any selectable profile
  /// remains. [plexHomeUsers] is [PlexHomeService.current]; stale entries for
  /// removed accounts are harmless because the connection map is re-read here.
  Future<({PostRemovalRoute route, List<Profile> profiles})> resolvePostRemovalState({
    required ProfileRegistry profileRegistry,
    required Map<String, List<PlexHomeUser>> plexHomeUsers,
  }) async {
    await pruneUnreferencedJellyfinConnections();
    final conns = await connections.list();
    if (conns.isEmpty) return (route: PostRemovalRoute.signedOut, profiles: const <Profile>[]);

    final merged = mergeLocalWithPlexHome(
      locals: await profileRegistry.list(),
      plexHomeByConnectionId: plexHomeUsers,
      connectionsById: {for (final c in conns) c.id: c},
      storage: storage,
    );
    if (merged.isEmpty) return (route: PostRemovalRoute.signedOut, profiles: const <Profile>[]);
    return (route: PostRemovalRoute.staySignedIn, profiles: merged);
  }

  /// The Jellyfin-era method name is retained for existing callers;
  /// [JellyfinConnection] represents both Jellyfin and Emby.
  Future<int> pruneUnreferencedJellyfinConnections() async {
    final all = await connections.list();
    final referencedConnectionIds = (await profileConnections.listAll()).map((row) => row.connectionId).toSet();
    var removed = 0;

    for (final connection in all.whereType<JellyfinConnection>()) {
      if (referencedConnectionIds.contains(connection.id)) continue;
      await _removeJellyfinConnection(connection);
      removed++;
    }

    return removed;
  }

  Future<void> _removeUnreferencedJellyfinConnection(JellyfinConnection connection) async {
    if ((await profileConnections.listForConnection(connection.id)).isNotEmpty) return;
    await _removeJellyfinConnection(connection);
  }

  Future<void> _removeJellyfinConnection(JellyfinConnection connection) async {
    await connections.remove(connection.id);
    serverManager?.removeJellyfinConnection(connection);
    final serverId = ServerId.tryParse(connection.serverMachineId);
    if (serverId != null && !await _isServerReferenced(serverId)) {
      await storage.clearLibraryPreferencesForServerEverywhere(serverId);
    }
  }

  Future<void> _clearProfileServerPrefsNoLongerReferenced({
    required String profileId,
    required Set<ServerId> removedServerIds,
    required bool clearEverywhereWhenUnreferenced,
  }) async {
    if (removedServerIds.isEmpty) return;
    final remainingProfileServerIds = await _serverIdsForProfile(profileId);
    final activeProfileId = storage.getActiveProfileId();

    for (final serverId in removedServerIds) {
      if (remainingProfileServerIds.contains(serverId)) continue;
      final serverStillReferenced = await _isServerReferenced(serverId);
      if (serverStillReferenced || !clearEverywhereWhenUnreferenced) {
        await storage.clearLibraryPreferencesForServer(
          serverId,
          profileId: profileId,
          includeLegacy: activeProfileId == profileId,
        );
      } else {
        await storage.clearLibraryPreferencesForServerEverywhere(serverId);
      }
    }
  }

  /// Server ids reachable through this profile's join rows. Narrower than
  /// `ActiveProfileBinder._expectedServerIdsForProfile`: an implicit Plex Home
  /// parent is not counted here, so folding the two together would change which
  /// per-profile prefs survive an unlink.
  Future<Set<ServerId>> _serverIdsForProfile(String profileId) async {
    final rows = await profileConnections.listForProfile(profileId);
    if (rows.isEmpty) return const {};

    final all = await connections.list();
    final byId = {for (final connection in all) connection.id: connection};
    return {
      for (final row in rows)
        if (byId[row.connectionId] case final connection?) ..._serverIdsForConnection(connection),
    };
  }

  Future<bool> _isServerReferenced(ServerId serverId) async {
    final rows = await profileConnections.listAll();
    if (rows.isEmpty) return false;

    final all = await connections.list();
    final byId = {for (final connection in all) connection.id: connection};
    for (final row in rows) {
      final connection = byId[row.connectionId];
      if (connection != null && _serverIdsForConnection(connection).contains(serverId)) return true;
    }
    return false;
  }
}

// [ServerId]-typed for the preference APIs, which drops ids that fail to
// parse; the twin in profile_detail_screen.dart stays raw so it can be
// differenced against download keys.
Set<ServerId> _serverIdsForConnection(Connection connection) {
  return switch (connection) {
    PlexAccountConnection(:final servers) => {
      for (final server in servers) ?ServerId.tryParse(server.clientIdentifier),
    },
    JellyfinConnection(:final serverMachineId) => {?ServerId.tryParse(serverMachineId)},
  };
}
