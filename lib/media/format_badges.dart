import 'media_display_criteria.dart';
import 'media_source_info.dart';

/// One mark in the playback corner's format row: a logo where one exists
/// (white, `assets/format_logos/`), else short text in the same style.
class FormatBadge {
  /// Words for screen readers and for the text fallback.
  final String label;

  /// Asset path of the logo, or null for a text badge.
  final String? logo;

  const FormatBadge(this.label, {this.logo});

  @override
  bool operator ==(Object other) => other is FormatBadge && other.label == label && other.logo == logo;

  @override
  int get hashCode => Object.hash(label, logo);

  @override
  String toString() => logo == null ? 'FormatBadge($label)' : 'FormatBadge($label, $logo)';
}

const _logos = 'assets/format_logos';

/// The playing file's resolution, HDR kind and audio, in that order (Adrian,
/// 2026-10-31: "the resolution, audio codec, and HDR flag ... use the logos
/// where available"). Describes the source file, not what a server conversion
/// sends; the quality picker says when the server converts.
List<FormatBadge> formatBadges({int? width, int? height, MediaDisplayCriteria? display, MediaAudioTrack? audio}) {
  return [?_resolution(width ?? display?.width, height ?? display?.height), ?_hdr(display), ..._audio(audio)];
}

/// 4K / 1080p / 720p / SD. Width counts too, so a 2.39:1 film cropped to
/// 1920x800 still reads 1080p.
FormatBadge? _resolution(int? width, int? height) {
  final w = width ?? 0;
  final h = height ?? 0;
  if (w <= 0 && h <= 0) return null;
  if (w >= 3200 || h >= 1600) return const FormatBadge('4K', logo: '$_logos/uhd_4k.svg');
  if (w >= 1700 || h >= 900) return const FormatBadge('1080p');
  if (w >= 1100 || h >= 650) return const FormatBadge('720p');
  return const FormatBadge('SD');
}

/// Dolby Vision / HDR10+ / HDR10 / HLG; nothing for SDR. The server's own
/// range name decides first (it alone knows HDR10+), then the colour tags.
FormatBadge? _hdr(MediaDisplayCriteria? display) {
  if (display == null) return null;
  final range = (display.rangeType ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9+]'), '');
  if (range.contains('dovi') || range.contains('dolbyvision')) return dolbyVisionBadge;
  if (range.contains('hdr10plus') || range.contains('hdr10+')) return hdr10PlusBadge;
  if (range.contains('hlg')) return const FormatBadge('HLG');
  if (range.contains('hdr10')) return hdr10Badge;
  return switch (display.colorType) {
    MediaDisplayColorType.dolbyVision => dolbyVisionBadge,
    MediaDisplayColorType.pq => hdr10Badge,
    MediaDisplayColorType.hlg => const FormatBadge('HLG'),
    MediaDisplayColorType.sdr || MediaDisplayColorType.unknown => null,
  };
}

const dolbyVisionBadge = FormatBadge('Dolby Vision', logo: '$_logos/dolby_vision.svg');
const hdr10PlusBadge = FormatBadge('HDR10+', logo: '$_logos/hdr10_plus.svg');
const hdr10Badge = FormatBadge('HDR10', logo: '$_logos/hdr10.svg');

/// The audio format (Atmos and DTS:X first, as the spatial layer is what the
/// track is known by), then its channels.
List<FormatBadge> _audio(MediaAudioTrack? track) {
  if (track == null) return const [];
  final codec = (track.codec ?? '').toLowerCase();
  final spatial = (track.spatialFormat ?? '').toLowerCase();
  final words = [track.profile, track.displayTitle, track.title].whereType<String>().join(' ').toLowerCase();
  final format = switch (codec) {
    _ when spatial.contains('atmos') || words.contains('atmos') => const FormatBadge(
      'Dolby Atmos',
      logo: '$_logos/dolby_atmos.svg',
    ),
    _ when spatial.contains('dtsx') || words.contains('dts:x') || words.contains('dts-x') => const FormatBadge(
      'DTS:X',
      logo: '$_logos/dts_x.svg',
    ),
    'truehd' || 'mlp' => const FormatBadge('Dolby TrueHD', logo: '$_logos/dolby_truehd.svg'),
    'eac3' || 'e-ac-3' || 'ec-3' => const FormatBadge('Dolby Digital Plus', logo: '$_logos/dolby_digital_plus.svg'),
    'ac3' || 'ac-3' => const FormatBadge('Dolby Digital', logo: '$_logos/dolby_digital.svg'),
    'dts' || 'dca' when _dtsMasterAudio.hasMatch(words) => const FormatBadge(
      'DTS-HD Master Audio',
      logo: '$_logos/dts_hd_ma.svg',
    ),
    'dts' || 'dca' when words.contains('dts-hd') || RegExp(r'\bhra\b').hasMatch(words) => const FormatBadge(
      'DTS-HD',
      logo: '$_logos/dts.svg',
    ),
    'dts' || 'dca' => const FormatBadge('DTS', logo: '$_logos/dts.svg'),
    '' => null,
    _ => FormatBadge(_codecName(codec)),
  };
  final channels = _channels(track.channels);
  return [?format, ?channels];
}

/// "DTS-HD MA" (Jellyfin's profile) or "Master Audio"; a bare "ma" must be a
/// word of its own, or "German" would count.
final _dtsMasterAudio = RegExp(r'master audio|\bdts-hd ma\b|\bma\b');

String _codecName(String codec) => switch (codec) {
  'aac' => 'AAC',
  'flac' => 'FLAC',
  'opus' => 'Opus',
  'vorbis' => 'Vorbis',
  'mp3' => 'MP3',
  'alac' => 'ALAC',
  _ when codec.startsWith('pcm') => 'PCM',
  _ => codec.toUpperCase(),
};

FormatBadge? _channels(int? channels) => switch (channels) {
  null || <= 0 => null,
  1 => const FormatBadge('Mono'),
  2 => const FormatBadge('Stereo'),
  3 => const FormatBadge('2.1'),
  6 => const FormatBadge('5.1'),
  7 => const FormatBadge('6.1'),
  8 => const FormatBadge('7.1'),
  _ => FormatBadge('$channels ch'),
};
