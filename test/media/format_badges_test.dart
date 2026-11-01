import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/format_badges.dart';
import 'package:plezy/media/media_display_criteria.dart';
import 'package:plezy/media/media_source_info.dart';

MediaAudioTrack _audio(String codec, {int? channels, String? profile, String? spatial, String? displayTitle}) =>
    MediaAudioTrack(
      id: 1,
      codec: codec,
      channels: channels,
      profile: profile,
      spatialFormat: spatial,
      displayTitle: displayTitle,
      selected: true,
    );

List<String> _labels(List<FormatBadge> badges) => [for (final b in badges) b.label];

void main() {
  group('resolution', () {
    test('4K, 1080p, 720p and SD by height', () {
      expect(_labels(formatBadges(width: 3840, height: 2160)), ['4K']);
      expect(_labels(formatBadges(width: 1920, height: 1080)), ['1080p']);
      expect(_labels(formatBadges(width: 1280, height: 720)), ['720p']);
      expect(_labels(formatBadges(width: 720, height: 480)), ['SD']);
    });

    test('a cropped wide film keeps its tier by width', () {
      expect(_labels(formatBadges(width: 1920, height: 800)), ['1080p']);
      expect(_labels(formatBadges(width: 3840, height: 1600)), ['4K']);
    });

    test('nothing known, no badge', () {
      expect(formatBadges(), isEmpty);
    });
  });

  group('HDR', () {
    test("the server's range name tells HDR10+ from HDR10 and Dolby Vision", () {
      expect(formatBadges(display: const MediaDisplayCriteria(rangeType: 'HDR10Plus')), [hdr10PlusBadge]);
      expect(formatBadges(display: const MediaDisplayCriteria(rangeType: 'HDR10')), [hdr10Badge]);
      expect(formatBadges(display: const MediaDisplayCriteria(rangeType: 'DOVIWithHDR10')), [dolbyVisionBadge]);
      expect(_labels(formatBadges(display: const MediaDisplayCriteria(rangeType: 'HLG'))), ['HLG']);
    });

    test('without a range name the colour tags decide; SDR shows nothing', () {
      expect(formatBadges(display: const MediaDisplayCriteria(doviProfile: 5)), [dolbyVisionBadge]);
      expect(formatBadges(display: const MediaDisplayCriteria(transfer: 'smpte2084')), [hdr10Badge]);
      expect(
        formatBadges(
          display: const MediaDisplayCriteria(rangeType: 'SDR', transfer: 'bt709'),
        ),
        isEmpty,
      );
    });
  });

  group('audio', () {
    test('Atmos and DTS:X win over the codec underneath', () {
      expect(_labels(formatBadges(audio: _audio('truehd', channels: 8, spatial: 'DolbyAtmos'))), [
        'Dolby Atmos',
        '7.1',
      ]);
      expect(_labels(formatBadges(audio: _audio('eac3', channels: 6, profile: 'Dolby Digital Plus + Dolby Atmos'))), [
        'Dolby Atmos',
        '5.1',
      ]);
      expect(_labels(formatBadges(audio: _audio('dts', channels: 8, spatial: 'DTSX'))), ['DTS:X', '7.1']);
    });

    test('Dolby and DTS codecs get their logos', () {
      final cases = {
        _audio('truehd'): 'dolby_truehd.svg',
        _audio('eac3'): 'dolby_digital_plus.svg',
        _audio('ac3'): 'dolby_digital.svg',
        _audio('dts', profile: 'DTS-HD MA'): 'dts_hd_ma.svg',
        _audio('dts'): 'dts.svg',
      };
      for (final MapEntry(key: track, value: logo) in cases.entries) {
        expect(formatBadges(audio: track).single.logo, endsWith(logo), reason: track.codec);
      }
    });

    test('a language name with "ma" in it is not DTS-HD Master Audio', () {
      final badges = formatBadges(audio: _audio('dts', displayTitle: 'German - DTS - 5.1'));
      expect(badges.first.label, 'DTS');
    });

    test('other codecs are plain text, with channels', () {
      expect(_labels(formatBadges(audio: _audio('aac', channels: 2))), ['AAC', 'Stereo']);
      expect(_labels(formatBadges(audio: _audio('flac', channels: 6))), ['FLAC', '5.1']);
      expect(formatBadges(audio: _audio('aac')).single.logo, isNull);
    });
  });

  test('order is resolution, HDR, then audio', () {
    final badges = formatBadges(
      width: 3840,
      height: 2160,
      display: const MediaDisplayCriteria(rangeType: 'DOVIWithHDR10'),
      audio: _audio('truehd', channels: 8, spatial: 'DolbyAtmos'),
    );
    expect(_labels(badges), ['4K', 'Dolby Vision', 'Dolby Atmos', '7.1']);
  });
}
