import 'dart:async';

/// A message a media server asked this app to show on screen: Jellyfin's
/// `GeneralCommand` `DisplayMessage`, sent with `POST /Sessions/{id}/Message`.
/// Media Bridge uses it to say "Upgrade Ready" while the film or episode being
/// watched has just been replaced by a better copy (PLAN_PMB_91;
/// local/plans/new-copy-toast.md).
class ServerMessage {
  const ServerMessage({required this.serverId, required this.text, this.header, this.timeout});

  final String serverId;
  final String text;
  final String? header;

  /// How long to show it; null = the app's default.
  final Duration? timeout;

  /// Reads a `DisplayMessage` command's arguments (Jellyfin sends every value as
  /// a string); null when there is no text.
  static ServerMessage? fromArguments(String serverId, Object? arguments) {
    if (arguments is! Map) return null;
    String? read(String key) {
      final value = arguments[key] ?? arguments[key[0].toLowerCase() + key.substring(1)];
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    final text = read('Text');
    if (text == null) return null;
    final ms = int.tryParse(read('TimeoutMs') ?? '');
    return ServerMessage(
      serverId: serverId,
      text: text,
      header: read('Header'),
      timeout: ms == null || ms <= 0 ? null : Duration(milliseconds: ms),
    );
  }
}

/// Where server messages arrive; the player shows them.
class ServerMessages {
  ServerMessages._();
  static final instance = ServerMessages._();

  final _controller = StreamController<ServerMessage>.broadcast();

  Stream<ServerMessage> get stream => _controller.stream;

  void add(ServerMessage message) => _controller.add(message);
}
