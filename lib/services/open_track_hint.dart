import '../media/media_source_info.dart';
import '../mpv/models.dart';
import 'playback_subtitle_resolver.dart';

/// mpv track ids to select in the `loadfile` itself, so the file opens on the
/// tracks the player is about to pick anyway.
///
/// Today a file opens with `sid=no` and the subtitle is switched on once mpv
/// has listed the tracks. Switching a subtitle on mid-file makes mpv "refresh
/// seek" back about 11 s to collect the subtitle's packets, which opens one
/// more HTTP range request on every start (2026-10-14, Greatroom TV log), and
/// each abandoned request costs the server, and an outside viewer's Cloudflare
/// path, megabytes. Selecting the same track at load makes the later choice a
/// no-op (mpv ignores a write of the track already selected).
///
/// This is only a hint. mpv numbers a file's own tracks per type in container
/// order, and the server lists them in the same order, so a container track's
/// position among the container tracks gives its mpv id. When the guess is
/// wrong the normal selection after the track list arrives corrects it, at the
/// cost the open already pays today. No hint is given where the order says
/// nothing: transcodes (the server rebuilds the stream), sidecar or external
/// subtitle files, and keyed rows.
class OpenTrackHint {
  const OpenTrackHint({this.audioId, this.subtitleId});

  static const none = OpenTrackHint();

  final String? audioId;
  final String? subtitleId;

  bool get isEmpty => audioId == null && subtitleId == null;

  static OpenTrackHint resolve({
    required MediaSourceInfo? mediaInfo,
    required bool isTranscoding,
    required PlaybackSubtitleSelection subtitleSelection,
    AudioTrack? selectedAudio,
  }) {
    if (mediaInfo == null || isTranscoding) return none;
    return OpenTrackHint(
      audioId: _audioId(mediaInfo, selectedAudio),
      subtitleId: _subtitleId(mediaInfo, subtitleSelection),
    );
  }

  static String? _subtitleId(MediaSourceInfo mediaInfo, PlaybackSubtitleSelection selection) {
    if (selection.isOff || selection.primarySidecar != null) return null;
    final sourceId = selection.primarySourceStreamId;
    if (sourceId == null) return null;
    final container = mediaInfo.subtitleTracks.where(_isContainerSubtitle).toList(growable: false);
    final ordinal = container.indexWhere((track) => track.id == sourceId);
    return ordinal < 0 ? null : '${ordinal + 1}';
  }

  static bool _isContainerSubtitle(MediaSubtitleTrack track) =>
      !track.external && (track.key == null || track.key!.isEmpty);

  static String? _audioId(MediaSourceInfo mediaInfo, AudioTrack? selectedAudio) {
    final id = selectedAudio?.id;
    if (id == null || !id.startsWith('source:')) return null;
    final sourceId = int.tryParse(id.substring('source:'.length));
    if (sourceId == null) return null;
    final container = mediaInfo.audioTracks.where((track) => !track.external).toList(growable: false);
    final ordinal = container.indexWhere((track) => track.id == sourceId);
    return ordinal < 0 ? null : '${ordinal + 1}';
  }
}
