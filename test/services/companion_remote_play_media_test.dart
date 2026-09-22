import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/services/companion_remote/companion_remote_receiver.dart';

void main() {
  group('playMedia command', () {
    tearDown(() {
      CompanionRemoteReceiver.instance.onPlayMedia = null;
    });

    test('wire indexes of existing commands never move', () {
      // RemoteCommand serialises the type by index, so a value inserted
      // anywhere but the end mispairs with peers on an older build. These
      // indexes are the wire format; changing one is a breaking change.
      expect(RemoteCommandType.dpadUp.index, 0);
      expect(RemoteCommandType.select.index, 4);
      expect(RemoteCommandType.play.index, 7);
      expect(RemoteCommandType.ping.index, 34);
      expect(RemoteCommandType.syncState.index, 39);
      expect(RemoteCommandType.playMedia.index, RemoteCommandType.values.length - 1);
    });

    test('round-trips through JSON with its payload', () {
      const command = RemoteCommand(
        type: RemoteCommandType.playMedia,
        data: {'serverId': 'abc123', 'ratingKey': '1248'},
      );

      final decoded = RemoteCommand.fromJson(command.toJson());

      expect(decoded.type, RemoteCommandType.playMedia);
      expect(decoded.data?['serverId'], 'abc123');
      expect(decoded.data?['ratingKey'], '1248');
    });

    test('reaches onPlayMedia with both identifiers', () {
      String? seenServerId;
      String? seenRatingKey;
      CompanionRemoteReceiver.instance.onPlayMedia = (serverId, ratingKey) {
        seenServerId = serverId;
        seenRatingKey = ratingKey;
      };

      CompanionRemoteReceiver.instance.handleCommand(
        const RemoteCommand(type: RemoteCommandType.playMedia, data: {'serverId': 'abc123', 'ratingKey': '1248'}),
        null,
      );

      expect(seenServerId, 'abc123');
      expect(seenRatingKey, '1248');
    });

    test('is ignored when an identifier is missing or empty', () {
      var calls = 0;
      CompanionRemoteReceiver.instance.onPlayMedia = (_, _) => calls++;

      for (final data in <Map<String, dynamic>?>[
        null,
        <String, dynamic>{},
        {'serverId': 'abc123'},
        {'ratingKey': '1248'},
        {'serverId': '', 'ratingKey': '1248'},
        {'serverId': 'abc123', 'ratingKey': ''},
      ]) {
        CompanionRemoteReceiver.instance.handleCommand(
          RemoteCommand(type: RemoteCommandType.playMedia, data: data),
          null,
        );
      }

      expect(calls, 0);
    });
  });
}
