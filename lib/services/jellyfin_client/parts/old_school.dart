part of '../../jellyfin_client.dart';

/// Old School's calls on a PlezyFin server (PLAN_SHA_21, route
/// `PlezyFin/OldSchool`). Only offered when `PlezyFinVersion` is 2 or later.
mixin _JellyfinOldSchoolMethods on _JellyfinClientInternals {
  static const _base = '/PlezyFin/OldSchool';

  /// The enabled channels, in number order. Seasonal channels appear only in
  /// their date windows (the server decides).
  Future<List<OldSchoolChannel>> fetchOldSchoolChannels() async {
    final response = await _http.get('$_base/Channels');
    throwIfHttpError(response);
    final data = response.data;
    final list = data is List ? data : (data is Map ? (data['Items'] ?? data['items'] ?? data['Channels']) : null);
    final channels = [
      if (list is List)
        for (final json in list) ?OldSchoolChannel.fromJson(json),
    ]..sort((a, b) => a.number.compareTo(b.number));
    return channels;
  }

  /// Every channel's entries overlapping [hours] hours from [start].
  Future<OldSchoolGuide> fetchOldSchoolGuide({required DateTime start, required int hours}) async {
    final response = await _http.get(
      '$_base/Guide',
      queryParameters: {'start': start.toUtc().toIso8601String(), 'hours': '${hours.clamp(1, 24)}'},
    );
    throwIfHttpError(response);
    final guide = OldSchoolGuide.fromJson(response.data);
    if (guide == null) throw const FormatException('Old School guide answer had no serverTime');
    return guide;
  }

  /// What is on [channelId] now and next. The server registers both as Old
  /// School plays for this session, so they are not counted as watched.
  Future<OldSchoolTune> tuneOldSchool(String channelId) async {
    final response = await _http.get('$_base/Tune/${Uri.encodeComponent(channelId)}');
    throwIfHttpError(response);
    final tune = OldSchoolTune.fromJson(channelId, response.data, receivedAt: DateTime.now());
    if (tune == null) throw const FormatException('Old School tune answer had no serverTime or now entry');
    return tune;
  }

  /// A channel's logo as a transparent PNG about [width] physical pixels
  /// wide. No sign-in needed; the server clamps the width to 16-1024 and
  /// rounds it up to a step of 8, so this does the same to share its cache.
  String oldSchoolLogoUrl(OldSchoolChannel channel, {required int width}) {
    final step = ((width.clamp(16, 1024) + 7) ~/ 8) * 8;
    final uri = JellyfinImageAbsolutizer.joinUri(
      baseUrl: connection.baseUrl,
      urlOrPath: '$_base/Channels/${Uri.encodeComponent(channel.id)}/Logo',
    );
    return uri
        .replace(
          queryParameters: {'format': 'png', 'maxWidth': '$step', if (channel.logoTag != null) 'tag': channel.logoTag!},
        )
        .toString();
  }
}
