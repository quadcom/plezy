import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/windows_app_updater.dart';

Map<String, dynamic> _asset(String name) => {'name': name, 'url': 'https://example.test/$name', 'size': 1};

void main() {
  test('picks the setup file from a release', () {
    final release = [
      _asset('plezy-2026.10.30-arm64-v8a.apk'),
      _asset('plezy-2026.10.30-windows-x64.zip'),
      _asset('plezy-2026.10.30-windows-x64-setup.exe'),
    ];
    expect(WindowsAppUpdater.pickSetupAsset(release)?['name'], 'plezy-2026.10.30-windows-x64-setup.exe');
  });

  test('a release with only the portable zip means no in-app install', () {
    expect(WindowsAppUpdater.pickSetupAsset([_asset('plezy-2026.10.29-windows-x64.zip')]), isNull);
    expect(WindowsAppUpdater.pickSetupAsset([_asset('plezy-windows-installer.exe')]), isNull);
  });

  test('setup runs silently and closes a running Plezy', () {
    expect(WindowsAppUpdater.installerArguments, containsAll(['/SILENT', '/SP-', '/CLOSEAPPLICATIONS']));
  });
}
