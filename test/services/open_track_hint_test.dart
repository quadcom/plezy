import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/jellyfin_media_info_mapper.dart';
import 'package:plezy/services/open_track_hint.dart';
import 'package:plezy/services/playback_subtitle_resolver.dart';

/// The hint picks mpv's per-type track number from the server's container
/// order, so a file can open on the tracks the player is about to choose.
void main() {
  // Shaped like WAR (2026) S01E02 on PlezyFin: one video, two audio, embedded
  // SubRip rows, plus one external subtitle file.
  final MediaSourceInfo war = jellyfinMediaSourceToMediaSourceInfo({
    'Id': 'src-1',
    'MediaStreams': [
      {'Index': 0, 'Type': 'Video', 'Codec': 'hevc'},
      {'Index': 1, 'Type': 'Audio', 'Language': 'eng', 'IsDefault': true},
      {'Index': 2, 'Type': 'Audio', 'Language': 'fra'},
      {'Index': 3, 'Type': 'Subtitle', 'Language': 'eng', 'Codec': 'subrip', 'Title': 'American English'},
      {'Index': 4, 'Type': 'Subtitle', 'Language': 'eng', 'Codec': 'subrip', 'Title': 'American English [CC]'},
      {'Index': 5, 'Type': 'Subtitle', 'Language': 'por', 'Codec': 'subrip'},
      {'Index': 6, 'Type': 'Subtitle', 'Language': 'ind', 'Codec': 'subrip'},
      {'Index': 7, 'Type': 'Subtitle', 'Language': 'spa', 'Codec': 'subrip', 'IsExternal': true, 'Path': '/x.spa.srt'},
    ],
  });

  MediaSubtitleTrack subtitle(String language) => war.subtitleTracks.firstWhere((t) => t.language == language);

  PlaybackSubtitleSelection chose(MediaSubtitleTrack track) => PlaybackSubtitleSelection(
    primaryTrack: SubtitleTrack(id: 'source:${track.id}'),
    primarySourceStreamId: track.id,
  );

  OpenTrackHint hint(PlaybackSubtitleSelection selection, {bool isTranscoding = false, AudioTrack? audio}) =>
      OpenTrackHint.resolve(
        mediaInfo: war,
        isTranscoding: isTranscoding,
        subtitleSelection: selection,
        selectedAudio: audio,
      );

  test('an embedded subtitle maps to its place among the embedded subtitles', () {
    expect(hint(chose(war.subtitleTracks.first)).subtitleId, '1');
    expect(hint(chose(subtitle('ind'))).subtitleId, '4');
  });

  test('subtitles off gives no subtitle hint', () {
    expect(hint(const PlaybackSubtitleSelection.off()).subtitleId, isNull);
  });

  test('an external subtitle file gives no hint', () {
    final external = war.subtitleTracks.firstWhere((t) => t.external);
    expect(hint(chose(external)).subtitleId, isNull);
  });

  test('a transcode gives no hint at all', () {
    final result = hint(chose(war.subtitleTracks.first), isTranscoding: true, audio: _audio(war.audioTracks.last));
    expect(result.isEmpty, isTrue);
  });

  test('the chosen audio maps to its place among the audio tracks', () {
    expect(hint(const PlaybackSubtitleSelection.off(), audio: _audio(war.audioTracks.first)).audioId, '1');
    expect(hint(const PlaybackSubtitleSelection.off(), audio: _audio(war.audioTracks.last)).audioId, '2');
  });

  test('an audio track that is not a server row gives no audio hint', () {
    expect(hint(const PlaybackSubtitleSelection.off(), audio: const AudioTrack(id: '2')).audioId, isNull);
  });
}

AudioTrack _audio(MediaAudioTrack track) => PlaybackSubtitleResolver.audioTrackForSource(track);
