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

  test('the debug logging setting still holds while the file is off', () async {
    setLoggerLevel(true);
    await DevLogFile.setSwitch(true);
    await DevLogFile.setSwitch(false);
    expect(debugLoggingEnabled, isTrue);
  });
}
