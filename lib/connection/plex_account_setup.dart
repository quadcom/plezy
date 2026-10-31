import '../services/plex_auth_service.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
import 'connection.dart';

/// Result of [buildPlexAccountConnection]: the assembled connection plus the
/// raw identity fields callers fold into their own records and dedup scans.
typedef PlexAccountBuild = ({PlexAccountConnection connection, String username, String email, String accountUuid});

/// Shared token → [PlexAccountConnection] pipeline: resolve the plex.tv
/// account identity, list the account's servers, and assemble a connection
/// row stamped "now". Both [ConnectionBootstrap] entry points (the PLEX_TOKEN dev seed and the
/// legacy-token migration) funnel through here so the id/label policy can't
/// drift. Each caller keeps its delta via the knobs:
///
/// - [clientIdentifier] is persisted on the row and keys it when the account
///   uuid is unavailable. `null` uses the short-lived [PlexAuthService]'s own
///   per-device id (the same [StorageService]-backed value).
/// - [fetchUserInfo]/[fetchServers] override the identity/server sources —
///   the legacy migration injects a test seam and the cached legacy server
///   list. When both are given (and [clientIdentifier] is set) no
///   [PlexAuthService] is created at all.
/// - [keyByAccountUuid]: the dev seed keys its row by client id even when
///   the account uuid is known.
/// - [tolerateUserInfoFailure]: sign-in and migration fall back to a
///   client-id-keyed row when the identity lookup fails; the dev seed aborts
///   instead of seeding a mislabelled row.
Future<PlexAccountBuild> buildPlexAccountConnection(
  String token, {
  String? clientIdentifier,
  Future<Map<String, dynamic>> Function(String token)? fetchUserInfo,
  Future<List<PlexServer>> Function(String token)? fetchServers,
  bool keyByAccountUuid = true,
  bool tolerateUserInfoFailure = true,
}) async {
  PlexAuthService? auth;
  try {
    if (clientIdentifier == null || fetchUserInfo == null || fetchServers == null) {
      auth = await PlexAuthService.create();
    }
    // Account identity from plex.tv — the uuid is what makes multi-account
    // work (the clientIdentifier is per-device and identical for every Plex
    // account on this install). Falls back to the client identifier only
    // when the user-info call fails outright; a later successful sign-in
    // migrates that legacy row via [_migrateLegacyClientIdRow].
    String username = '';
    String email = '';
    String accountUuid = '';
    try {
      final info = await (fetchUserInfo ?? auth!.getUserInfo)(token);
      username = (info['username'] as String?) ?? '';
      email = (info['email'] as String?) ?? '';
      accountUuid = (info['uuid'] as String?)?.trim() ?? '';
    } catch (e) {
      if (!tolerateUserInfoFailure) rethrow;
      appLogger.d('Plex user-info lookup failed (using fallback identity): $e');
    }

    final servers = await (fetchServers ?? auth!.fetchServers)(token);
    final clientId = clientIdentifier ?? auth!.clientIdentifier;
    final connection = PlexAccountConnection(
      id: 'plex.${keyByAccountUuid && accountUuid.isNotEmpty ? accountUuid : clientId}',
      accountToken: token,
      clientIdentifier: clientId,
      accountLabel: username.isNotEmpty ? username : (email.isNotEmpty ? email : 'Plex'),
      servers: servers,
      createdAt: DateTime.now(),
      lastAuthenticatedAt: DateTime.now(),
    );
    return (connection: connection, username: username, email: email, accountUuid: accountUuid);
  } finally {
    auth?.dispose();
  }
}
