import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/server_messages.dart';

/// Server messages (Jellyfin DisplayMessage), local/plans/new-copy-toast.md.
void main() {
  test("reads Media Bridge's message: text only, time as a string", () {
    final message = ServerMessage.fromArguments('srv', {'Text': 'Upgrade Ready', 'TimeoutMs': '15000'})!;
    expect(message.text, 'Upgrade Ready');
    expect(message.header, isNull);
    expect(message.timeout, const Duration(seconds: 15));
  });

  test('a header and camelCase keys are read too; no text is no message', () {
    final message = ServerMessage.fromArguments('srv', {'header': 'New copy', 'text': 'Ready', 'timeoutMs': 5000})!;
    expect(message.header, 'New copy');
    expect(message.timeout, const Duration(seconds: 5));
    expect(ServerMessage.fromArguments('srv', {'Header': 'Only a header'}), isNull);
    expect(ServerMessage.fromArguments('srv', 'not a map'), isNull);
  });

  test('a missing or zero time falls back to the app default', () {
    expect(ServerMessage.fromArguments('srv', {'Text': 'x'})!.timeout, isNull);
    expect(ServerMessage.fromArguments('srv', {'Text': 'x', 'TimeoutMs': '0'})!.timeout, isNull);
  });
}
