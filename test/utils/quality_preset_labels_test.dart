import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/server_conversion.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/utils/quality_preset_labels.dart';

void main() {
  group('qualityPresetLabel', () {
    test('original returns "Original" (default English locale)', () {
      expect(qualityPresetLabel(TranscodeQualityPreset.original), 'Original');
      expect(qualityPresetLabel(TranscodeQualityPreset.original, sourceBitrateKbps: 12400), 'Original 12.4 Mbps');
      expect(qualityPresetLabel(TranscodeQualityPreset.original, sourceBitrateKbps: 0), 'Original');
    });

    test('integer-mbps preset renders without decimal', () {
      // 2000 kbps -> 2 Mbps (whole number)
      expect(qualityPresetLabel(TranscodeQualityPreset.p720_2mbps), '720p 2 Mbps');
      expect(qualityPresetLabel(TranscodeQualityPreset.p720_2mbps, sourceBitrateKbps: 12400), '720p 2 Mbps');
    });

    test('fractional-mbps preset renders with one decimal', () {
      // 1500 kbps -> 1.5 Mbps
      expect(qualityPresetLabel(TranscodeQualityPreset.p480_1_5mbps), '480p 1.5 Mbps');
    });

    test('large bitrate (>=10 Mbps) drops decimal', () {
      // 10000 kbps -> 10 Mbps
      expect(qualityPresetLabel(TranscodeQualityPreset.p1080_10mbps), '1080p 10 Mbps');
      // 20000 kbps -> 20 Mbps
      expect(qualityPresetLabel(TranscodeQualityPreset.p1080_20mbps), '1080p 20 Mbps');
    });

    test('low-resolution presets have correct height', () {
      expect(qualityPresetLabel(TranscodeQualityPreset.p240_320), startsWith('240p '));
      expect(qualityPresetLabel(TranscodeQualityPreset.p320_720), startsWith('320p '));
    });

    test('all 1080p presets render with 1080p prefix', () {
      for (final preset in [
        TranscodeQualityPreset.p1080_8mbps,
        TranscodeQualityPreset.p1080_10mbps,
        TranscodeQualityPreset.p1080_12mbps,
        TranscodeQualityPreset.p1080_20mbps,
      ]) {
        expect(qualityPresetLabel(preset), startsWith('1080p '));
      }
    });

    test('all 720p presets render with 720p prefix', () {
      for (final preset in [
        TranscodeQualityPreset.p720_2mbps,
        TranscodeQualityPreset.p720_3mbps,
        TranscodeQualityPreset.p720_4mbps,
      ]) {
        expect(qualityPresetLabel(preset), startsWith('720p '));
      }
    });

    test('every non-original preset renders without throwing', () {
      for (final preset in TranscodeQualityPreset.values) {
        expect(qualityPresetLabel(preset), isNotEmpty);
      }
    });
  });

  group('qualityPresetSizeEstimate', () {
    test('returns null when sourceDurationMs is null', () {
      expect(
        qualityPresetSizeEstimate(
          preset: TranscodeQualityPreset.p720_2mbps,
          sourceBitrateKbps: 5000,
          sourceDurationMs: null,
        ),
        isNull,
      );
    });

    test('returns null when sourceDurationMs is 0 or negative', () {
      expect(
        qualityPresetSizeEstimate(
          preset: TranscodeQualityPreset.p720_2mbps,
          sourceBitrateKbps: 5000,
          sourceDurationMs: 0,
        ),
        isNull,
      );
      expect(
        qualityPresetSizeEstimate(
          preset: TranscodeQualityPreset.p720_2mbps,
          sourceBitrateKbps: 5000,
          sourceDurationMs: -100,
        ),
        isNull,
      );
    });

    test('original returns null when source bitrate is missing or zero', () {
      expect(
        qualityPresetSizeEstimate(
          preset: TranscodeQualityPreset.original,
          sourceBitrateKbps: null,
          sourceDurationMs: 1000,
        ),
        isNull,
      );
      expect(
        qualityPresetSizeEstimate(
          preset: TranscodeQualityPreset.original,
          sourceBitrateKbps: 0,
          sourceDurationMs: 1000,
        ),
        isNull,
      );
    });

    test('original returns formatted byte size with no percentage', () {
      // 1000 kbps * 1000 ms / 8 = 125000 bytes -> "122.1 KB"
      final result = qualityPresetSizeEstimate(
        preset: TranscodeQualityPreset.original,
        sourceBitrateKbps: 1000,
        sourceDurationMs: 1000,
      );
      expect(result, isNotNull);
      // Should not contain a percentage marker.
      expect(result!.contains('%'), isFalse);
    });

    test('non-original preset includes percentage when source bitrate is provided', () {
      final result = qualityPresetSizeEstimate(
        preset: TranscodeQualityPreset.p720_2mbps,
        sourceBitrateKbps: 8000,
        sourceDurationMs: 60 * 1000,
      );
      expect(result, isNotNull);
      expect(result!.contains('%'), isTrue);
      expect(result.contains('('), isTrue);
      expect(result.contains(')'), isTrue);
    });

    test('non-original preset omits percentage when source bitrate is null', () {
      final result = qualityPresetSizeEstimate(
        preset: TranscodeQualityPreset.p720_2mbps,
        sourceBitrateKbps: null,
        sourceDurationMs: 60 * 1000,
      );
      expect(result, isNotNull);
      expect(result!.contains('%'), isFalse);
    });

    test('non-original preset omits percentage when source bitrate is zero', () {
      final result = qualityPresetSizeEstimate(
        preset: TranscodeQualityPreset.p720_2mbps,
        sourceBitrateKbps: 0,
        sourceDurationMs: 60 * 1000,
      );
      expect(result, isNotNull);
      expect(result!.contains('%'), isFalse);
    });

    test('percentage uses video+audio bitrate ratio relative to source', () {
      // p720_2mbps -> 2000 video kbps + 192 audio = 2192 kbps total.
      // source = 8000 kbps -> 2192 * 100 / 8000 = 27.4 -> rounds to 27%.
      final result = qualityPresetSizeEstimate(
        preset: TranscodeQualityPreset.p720_2mbps,
        sourceBitrateKbps: 8000,
        sourceDurationMs: 60 * 1000,
      );
      expect(result, isNotNull);
      expect(result!.contains('27%'), isTrue);
    });

    test('larger source bitrate produces smaller percentage', () {
      final at4k = qualityPresetSizeEstimate(
        preset: TranscodeQualityPreset.p720_2mbps,
        sourceBitrateKbps: 40000,
        sourceDurationMs: 1000,
      );
      final at8k = qualityPresetSizeEstimate(
        preset: TranscodeQualityPreset.p720_2mbps,
        sourceBitrateKbps: 8000,
        sourceDurationMs: 1000,
      );
      // 4k source -> ~5%; 8k source -> ~27%.
      expect(at4k, isNotNull);
      expect(at8k, isNotNull);
      // Pull just the percentage out for a sanity comparison.
      final pctRe = RegExp(r'\((\d+)%\)');
      final pct4k = int.parse(pctRe.firstMatch(at4k!)!.group(1)!);
      final pct8k = int.parse(pctRe.firstMatch(at8k!)!.group(1)!);
      expect(pct4k, lessThan(pct8k));
    });
  });
  group('serverConversionLabel', () {
    const forcedRemote = ServerConversion(
      bitrateKbps: 7104,
      reasonCodes: ['AudioCodecNotSupported', 'ContainerBitrateExceedsLimit'],
      forced: true,
    );

    test('says what arrives, from the player, with the reasons in plain words', () {
      expect(
        serverConversionLabel(forcedRemote, width: 1920, height: 802, codec: 'HEVC'),
        'Converted by server: 1080p HEVC, 7.1 Mbps — outside the house limit, sound converted',
      );
    });

    test('the settings row leaves the reasons out', () {
      expect(
        serverConversionLabel(forcedRemote, width: 1920, height: 802, withReasons: false),
        'Converted by server: 1080p, 7.1 Mbps',
      );
    });

    test('falls back to the URL caps, then to the bare label', () {
      expect(
        serverConversionLabel(const ServerConversion(maxWidth: 1280, maxHeight: 720, forced: false)),
        'Converted by server: 720p',
      );
      expect(serverConversionLabel(const ServerConversion(forced: false)), 'Converted by server');
    });
  });

  group('streamVideoCodecLabel', () {
    test('names what mpv and ExoPlayer report the same way', () {
      expect(streamVideoCodecLabel('hevc'), 'HEVC');
      expect(streamVideoCodecLabel('video/hevc'), 'HEVC');
      expect(streamVideoCodecLabel('hvc1.2.4.L120.B0'), 'HEVC');
      expect(streamVideoCodecLabel('h264'), 'H.264');
      expect(streamVideoCodecLabel('video/avc'), 'H.264');
      expect(streamVideoCodecLabel('av01.0.08M.10'), 'AV1');
      expect(streamVideoCodecLabel(''), isNull);
      expect(streamVideoCodecLabel(null), isNull);
    });
  });
}
