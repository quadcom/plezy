import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/android_app_updater.dart';

Map<String, dynamic> _asset(String name) => {'name': name, 'url': 'https://example.test/$name', 'size': 1};

void main() {
  final splitRelease = [
    _asset('plezy-2026.10.1-arm64-v8a.apk'),
    _asset('plezy-2026.10.1-armeabi-v7a.apk'),
    _asset('plezy-2026.10.1-x86_64.apk'),
    _asset('notes.txt'),
  ];

  test('a 32-bit-only TV gets the armeabi-v7a APK', () {
    expect(
      AndroidAppUpdater.pickApkAsset(splitRelease, ['armeabi-v7a', 'armeabi'])?['name'],
      'plezy-2026.10.1-armeabi-v7a.apk',
    );
  });

  test('a 64-bit device gets its most preferred ABI', () {
    expect(
      AndroidAppUpdater.pickApkAsset(splitRelease, ['arm64-v8a', 'armeabi-v7a', 'armeabi'])?['name'],
      'plezy-2026.10.1-arm64-v8a.apk',
    );
  });

  test('falls back to a universal APK when no ABI matches', () {
    final release = [_asset('plezy-2026.10.1-arm64-v8a.apk'), _asset('plezy-2026.10.1.apk')];
    expect(AndroidAppUpdater.pickApkAsset(release, ['armeabi-v7a'])?['name'], 'plezy-2026.10.1.apk');
  });

  test('no APK for the device means no in-app install', () {
    expect(AndroidAppUpdater.pickApkAsset([_asset('plezy-2026.10.1-arm64-v8a.apk')], ['x86']), isNull);
    expect(AndroidAppUpdater.pickApkAsset([_asset('notes.txt')], ['arm64-v8a']), isNull);
  });
}
