part of '../../jellyfin_client.dart';

/// IPTV's calls on a PlezyFin server (PLAN_SHA_61, route `PlezyFin/Iptv`).
/// Only offered when `PlezyFinVersion` is 3 or later. The server hands out
/// pointers only: Plezy opens each channel's stream itself, straight from
/// its source.
mixin _JellyfinIptvMethods on _JellyfinClientInternals {
  static const _base = '/PlezyFin/Iptv';

  /// The channels of IPTV library [libraryId], in number order, each with its
  /// feeds best first.
  Future<IptvLineup> fetchIptvLineup(String libraryId) async {
    final response = await _http.get('$_base/${Uri.encodeComponent(libraryId)}/Channels');
    throwIfHttpError(response);
    final lineup = IptvLineup.fromJson(response.data, libraryId: libraryId);
    if (lineup == null) throw const FormatException('IPTV channel answer had no serverTime');
    return lineup;
  }

  /// Every channel's programmes overlapping [hours] hours (1-24) from [start].
  Future<IptvGuide> fetchIptvGuide(String libraryId, {required DateTime start, required int hours}) async {
    final response = await _http.get(
      '$_base/${Uri.encodeComponent(libraryId)}/Guide',
      queryParameters: {'start': start.toUtc().toIso8601String(), 'hours': '${hours.clamp(1, 24)}'},
    );
    throwIfHttpError(response);
    final guide = IptvGuide.fromJson(response.data);
    if (guide == null) throw const FormatException('IPTV guide answer had no serverTime');
    return guide;
  }

  /// A channel's logo (the item's Primary image), or null when it has none.
  String? iptvLogoUrl(IptvChannel channel, {required int width}) {
    final tag = channel.imageTag;
    if (tag == null) return null;
    return _absolutizeImagePath(
      '/Items/${_segment(channel.id)}/Images/Primary?tag=${Uri.encodeComponent(tag)}&maxWidth=${width.clamp(16, 1024)}',
    );
  }

  /// A programme's picture, cached by the server. No sign-in needed.
  String iptvProgrammeImageUrl(String libraryId, String imageId, {required int width}) {
    final uri = JellyfinImageAbsolutizer.joinUri(
      baseUrl: connection.baseUrl,
      urlOrPath: '$_base/${Uri.encodeComponent(libraryId)}/ProgramImages/${Uri.encodeComponent(imageId)}',
    );
    return uri.replace(queryParameters: {'maxWidth': '${width.clamp(16, 1920)}'}).toString();
  }

  /// Star or unstar a channel for this user (`UserData.IsFavorite`).
  Future<void> setIptvFavorite(String channelId, bool isFavorite) =>
      (this as JellyfinClient)._setItemFavorite(channelId, isFavorite);

  /// Whether [value] carries this server's own sign-in token. Pointer
  /// streams go to outside servers, which must never see it (plan 61
  /// refusal); a paid provider's own login is fine.
  bool carriesOwnToken(String value) {
    final token = connection.accessToken;
    return token.isNotEmpty && value.contains(token);
  }

  /// A playback session for [channel], starting at its best feed.
  IptvPlaybackSession startIptvPlayback(IptvChannel channel) => IptvPlaybackSession(this as JellyfinClient, channel);
}

/// Playing one IPTV channel. Nothing is negotiated with the server: the
/// player opens [feed] itself with exactly [headers]. On a failure the
/// player asks for [retryCurrent] (once, after the feed had played) or
/// [nextFeed]; null means every feed has failed.
///
/// The server only hears "started" and "stopped" (plan 61, answer 8): no
/// progress, and a channel is never marked played.
class IptvPlaybackSession implements LiveTvPlaybackSession {
  final JellyfinClient _client;
  final IptvChannel channel;
  final int feedIndex;

  /// The current feed already had its one retry after a drop.
  final bool retried;

  /// Shared by the sessions of one channel, so "started" goes once and
  /// "stopped" only after it.
  final _IptvReportState _report;

  IptvPlaybackSession(JellyfinClient client, IptvChannel channel)
    : this._(client, channel, 0, _IptvReportState(), retried: false);

  IptvPlaybackSession._(this._client, this.channel, this.feedIndex, this._report, {required this.retried});

  /// The feeds Plezy may open: in the server's order, minus any that would
  /// carry this server's own token.
  List<IptvFeed> get _feeds => [
    for (final feed in channel.feeds)
      if (!_client.carriesOwnToken(feed.url) && !feed.headers.values.any(_client.carriesOwnToken)) feed,
  ];

  IptvFeed? get feed {
    final feeds = _feeds;
    return feedIndex < feeds.length ? feeds[feedIndex] : null;
  }

  /// Exactly what the feed asks for, nothing added.
  Map<String, String> get headers => feed?.headers ?? const {};

  bool get hasFeed => feed != null;

  /// The same feed once more (a drop after it had played).
  IptvPlaybackSession? retryCurrent() =>
      retried || !hasFeed ? null : IptvPlaybackSession._(_client, channel, feedIndex, _report, retried: true);

  /// The next feed, or null when none is left.
  IptvPlaybackSession? nextFeed() {
    final next = feedIndex + 1;
    if (next >= _feeds.length) return null;
    return IptvPlaybackSession._(_client, channel, next, _report, retried: false);
  }

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  /// Nothing is held on the server, but a TV app sent to the background
  /// stops the picture and leaves, as Jellyfin Live TV does.
  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => false;

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async =>
      offsetSeconds == null && subtitleTrack == null ? feed?.url : null;

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    if (state == 'stopped') {
      if (!_report.started || _report.stopped) {
        appLogger.i('IPTV: stop report for ${channel.numberLabel} skipped (started ${_report.started})');
        return null;
      }
      _report.stopped = true;
      await _client.reportPlaybackStopped(
        itemId: channel.id,
        position: Duration.zero,
        playSessionId: _report.playSessionId,
      );
      return null;
    }
    if (_report.started) return null;
    _report.started = true;
    await _client.reportPlaybackStarted(
      itemId: channel.id,
      position: Duration.zero,
      playMethod: 'DirectPlay',
      playSessionId: _report.playSessionId,
    );
    return null;
  }

  /// Nothing to release: the server opened nothing.
  @override
  Future<void> discard() async {}

  /// The player's generic live retry ladder is not used for IPTV (it fails
  /// over between feeds instead); this keeps it harmless if reached.
  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) async =>
      retryCurrent() ?? nextFeed();
}

class _IptvReportState {
  /// One id for the start/stop pair, so the server sees one session row.
  final String playSessionId = 'plezy-iptv-${DateTime.now().microsecondsSinceEpoch}';
  bool started = false;
  bool stopped = false;
}
