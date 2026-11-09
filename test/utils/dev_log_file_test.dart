import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/dev_log_file.dart';

import '../test_helpers/io_fakes.dart';

/// The "Save Log to File" switch (local/plans/dev-mode-toggle.md): release
/// builds write the log file only while it is on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathProviderPlatform originalPlatform;

  setUp(() {
    originalPlatform = PathProviderPlatform.instance;
    tempRoot = Directory.systemTemp.createTempSync('dev_log_file_test');
    PathProviderPlatform.instance = FakePathProvider(tempRoot);
    setLoggerLevel(false);
  });

  tearDown(() async {
    await DevLogFile.setSwitch(false);
    setLoggerLevel(false);
    PathProviderPlatform.instance = originalPlatform;
    tempRoot.deleteSync(recursive: true);
  });

  File logFile() => File(p.join(tempRoot.path, 'support', 'logs', 'plezy-dev.log'));

  test('switching on opens the file and logs at debug level; off stops both', () async {
    expect(DevLogFile.enabled, isFalse);
    expect(debugLoggingEnabled, isFalse);

    await DevLogFile.setSwitch(true);
    expect(DevLogFile.enabled, isTrue);
    expect(debugLoggingEnabled, isTrue);
    appLogger.d('first line');
    expect(logFile().readAsStringSync(), contains('first line'));

    await DevLogFile.setSwitch(false);
    expect(DevLogFile.enabled, isFalse);
    expect(debugLoggingEnabled, isFalse);
    appLogger.w('after the switch');
    expect(logFile().readAsStringSync(), isNot(contains('after the switch')));
  });

  group('switch file', () {
    late File switchFile;
    var changes = 0;

    setUp(() async {
      DevLogFile.resetSwitchFile();
      changes = 0;
      DevLogFile.onEnabledChanged = () => changes++;
      switchFile = File((await DevLogFile.switchFilePath())!);
    });

    tearDown(() async {
      if (switchFile.existsSync()) switchFile.deleteSync();
      await DevLogFile.checkSwitchFile();
      DevLogFile.onEnabledChanged = null;
      DevLogFile.resetSwitchFile();
    });

    test('lives in the logs folder on desktop', () {
      expect(switchFile.path, p.join(tempRoot.path, 'support', 'logs', 'plezy-debug-on'));
    });

    test('turns developer mode on while it exists, without the setting', () async {
      await DevLogFile.checkSwitchFile();
      expect(DevLogFile.enabled, isFalse);
      expect(changes, 0);

      switchFile.createSync(recursive: true);
      await DevLogFile.checkSwitchFile();
      expect(DevLogFile.enabled, isTrue);
      expect(DevLogFile.switchedOnByFile, isTrue);
      expect(debugLoggingEnabled, isTrue);
      expect(changes, 1);

      await DevLogFile.checkSwitchFile();
      expect(changes, 1, reason: 'no change, no notice');

      switchFile.deleteSync();
      await DevLogFile.checkSwitchFile();
      expect(DevLogFile.enabled, isFalse);
      expect(changes, 2);
    });

    test('removing it leaves the setting in charge', () async {
      await DevLogFile.setSwitch(true);
      switchFile.createSync(recursive: true);
      await DevLogFile.checkSwitchFile();
      expect(DevLogFile.switchedOnByFile, isFalse, reason: 'the setting was on first');
      switchFile.deleteSync();
      await DevLogFile.checkSwitchFile();
      expect(DevLogFile.enabled, isTrue);
    });
  });

  test('the debug logging setting still holds while the file is off', () async {
    setLoggerLevel(true);
    await DevLogFile.setSwitch(true);
    await DevLogFile.setSwitch(false);
    expect(debugLoggingEnabled, isTrue);
  });
}
