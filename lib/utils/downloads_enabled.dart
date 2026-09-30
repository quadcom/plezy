import '../services/settings_service.dart';
import 'platform_detector.dart';

/// Whether download UI should be offered at all: never on Apple TV, which has
/// no user-accessible file storage, and elsewhere only while the viewer has
/// left [SettingsService.enableDownloads] on.
bool downloadsEnabled() =>
    !PlatformDetector.isAppleTV() && (SettingsService.instanceOrNull?.read(SettingsService.enableDownloads) ?? true);
