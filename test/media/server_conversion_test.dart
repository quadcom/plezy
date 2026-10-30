import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/server_conversion.dart';

void main() {
  // The shape PlezyFin answered with for JFK on the Tesla Screenmate, mobile data (2026-10-29).
  const remoteUrl =
      '/videos/abc/master.m3u8?DeviceId=d&MediaSourceId=abc&VideoCodec=hevc,h264&AudioCodec=aac'
      '&VideoBitrate=6464000&AudioBitrate=640000&PlaySessionId=p&SegmentContainer=mp4'
      '&TranscodeReasons=AudioCodecNotSupported,ContainerBitrateExceedsLimit';

  group('ServerConversion.fromTranscodingUrl', () {
    test('reads the bitrate, caps and reasons the server put in its URL', () {
      final conversion = ServerConversion.fromTranscodingUrl(remoteUrl, forced: true);

      expect(conversion.bitrateKbps, 7104);
      expect(conversion.maxWidth, isNull);
      expect(conversion.reasonCodes, ['AudioCodecNotSupported', 'ContainerBitrateExceedsLimit']);
      expect(conversion.reasons, [ServerConversionReason.bitrateLimit, ServerConversionReason.sound]);
    });

    test('a quality the user picked is not reported as a bitrate limit', () {
      final conversion = ServerConversion.fromTranscodingUrl(remoteUrl, forced: false);

      expect(conversion.reasons, [ServerConversionReason.sound]);
    });

    test('groups picture, subtitle and disc-image reasons and drops unknown codes', () {
      final conversion = ServerConversion.fromTranscodingUrl(
        '/videos/abc/master.m3u8?MaxWidth=1920&MaxHeight=1080'
        '&TranscodeReasons=VideoRangeTypeNotSupported,SubtitleCodecNotSupported,SomethingNew',
        forced: true,
        isDiscImage: true,
      );

      expect(conversion.maxWidth, 1920);
      expect(conversion.maxHeight, 1080);
      expect(conversion.bitrateKbps, isNull);
      expect(conversion.reasons, [
        ServerConversionReason.picture,
        ServerConversionReason.subtitles,
        ServerConversionReason.discImage,
      ]);
    });

    test('a URL with no query still gives an empty, usable summary', () {
      final conversion = ServerConversion.fromTranscodingUrl('/videos/abc/master.m3u8', forced: true);

      expect(conversion.bitrateKbps, isNull);
      expect(conversion.reasons, isEmpty);
    });
  });
}
