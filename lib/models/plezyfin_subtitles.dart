/// Subtitle search on a PlezyFin server (PlezyFin PLAN_PFN_103, routes
/// `PlezyFin/Subtitles/...`): the server passes the search to Bazarr, which
/// asks its own providers. Plan: local/plans/subtitle-search-plezyfin.md.
///
/// The readers take PascalCase (the server's casing) or camelCase keys, and
/// a missing field reads as empty rather than failing the whole answer.
library;

import '../utils/json_utils.dart';

Object? _field(Map json, String name) => json[name] ?? json[name[0].toLowerCase() + name.substring(1)];

String? _text(Map json, String name) {
  final value = _field(json, name)?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

/// One subtitle provider the server can't use right now, or its health in
/// the status answer.
class PlezyFinSubtitleProvider {
  final String name;
  final String? status;

  /// When the server tries the provider again ("in 4 hours"); null when it
  /// isn't waiting.
  final String? retry;

  const PlezyFinSubtitleProvider({required this.name, this.status, this.retry});

  /// The status answer names it `Name`; the plan's search shape `Provider`.
  /// Both are read.
  static PlezyFinSubtitleProvider? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = _text(json, 'Name') ?? _text(json, 'Provider');
    if (name == null) return null;
    final retry = _text(json, 'Retry');
    return PlezyFinSubtitleProvider(name: name, status: _text(json, 'Status'), retry: retry == '-' ? null : retry);
  }

  /// "opensubtitlescom: DownloadLimitExceeded, in 4 hours".
  String get summary => [
    name,
    if (status != null || retry != null) ': ${[?status, ?retry].join(', ')}',
  ].join();

  static List<PlezyFinSubtitleProvider> listFromJson(Object? json) => [
    if (json is List)
      for (final entry in json) ?PlezyFinSubtitleProvider.fromJson(entry),
  ];
}

/// `GET /PlezyFin/Subtitles/Status`.
class PlezyFinSubtitleStatus {
  /// The server has a subtitle source set up.
  final bool enabled;

  /// The signed-in user may download subtitles (their "Allow subtitle
  /// management" switch).
  final bool allowed;
  final List<PlezyFinSubtitleProvider> providers;

  const PlezyFinSubtitleStatus({required this.enabled, required this.allowed, this.providers = const []});

  /// The player's "Search subtitles" row shows only when both are true.
  bool get searchAvailable => enabled && allowed;

  static PlezyFinSubtitleStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return PlezyFinSubtitleStatus(
      enabled: flexibleBool(_field(json, 'Enabled')),
      allowed: flexibleBool(_field(json, 'Allowed')),
      providers: PlezyFinSubtitleProvider.listFromJson(_field(json, 'Providers')),
    );
  }
}

/// One subtitle the search found.
class PlezyFinSubtitleResult {
  /// Download id. The server forgets it after 30 minutes.
  final String id;
  final String? provider;
  final String? release;
  final int? score;

  /// Two-letter code, as asked for.
  final String? language;
  final bool forced;
  final bool hearingImpaired;
  final String? format;
  final String? uploader;

  const PlezyFinSubtitleResult({
    required this.id,
    this.provider,
    this.release,
    this.score,
    this.language,
    this.forced = false,
    this.hearingImpaired = false,
    this.format,
    this.uploader,
  });

  static PlezyFinSubtitleResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _text(json, 'Id');
    if (id == null) return null;
    final score = _field(json, 'Score');
    return PlezyFinSubtitleResult(
      id: id,
      provider: _text(json, 'Provider'),
      release: _text(json, 'Release'),
      score: flexibleInt(score) ?? flexibleDouble(score)?.round(),
      language: _text(json, 'Language'),
      forced: flexibleBool(_field(json, 'Forced')),
      hearingImpaired: flexibleBool(_field(json, 'HearingImpaired')),
      format: _text(json, 'Format'),
      uploader: _text(json, 'Uploader'),
    );
  }
}

/// `GET /PlezyFin/Subtitles/Search`. Always a 200: a search that found
/// nothing, or a provider at its daily limit, is an ordinary answer with
/// [ok] false and a sentence in [message] for the user.
class PlezyFinSubtitleSearch {
  final bool ok;
  final String? message;

  /// Best first (the server sorts by score).
  final List<PlezyFinSubtitleResult> results;

  /// Providers that couldn't be asked this time, and when they come back.
  final List<PlezyFinSubtitleProvider> unavailable;

  const PlezyFinSubtitleSearch({required this.ok, this.message, this.results = const [], this.unavailable = const []});

  static PlezyFinSubtitleSearch fromJson(Object? json) {
    if (json is! Map) return const PlezyFinSubtitleSearch(ok: false);
    return PlezyFinSubtitleSearch(
      ok: flexibleBool(_field(json, 'Ok')),
      message: _text(json, 'Message'),
      results: [
        for (final entry in flexibleList(_field(json, 'Results')) ?? const <dynamic>[])
          ?PlezyFinSubtitleResult.fromJson(entry),
      ],
      unavailable: PlezyFinSubtitleProvider.listFromJson(_field(json, 'Unavailable')),
    );
  }
}

/// `POST /PlezyFin/Subtitles/Download`: [ok] once the file is saved beside
/// the video; otherwise [message] says why, in a sentence for the user.
class PlezyFinSubtitleDownload {
  final bool ok;
  final String? message;

  /// The HTTP status when the server refused (403: not allowed, 400: no
  /// item), so the sheet can say so when the body has no sentence.
  final int? statusCode;

  const PlezyFinSubtitleDownload({required this.ok, this.message, this.statusCode});

  static PlezyFinSubtitleDownload fromJson(Object? json, {int? statusCode}) {
    if (json is Map) {
      return PlezyFinSubtitleDownload(
        ok: flexibleBool(_field(json, 'Ok')),
        message: _text(json, 'Message'),
        statusCode: statusCode,
      );
    }
    // Refusals (400) come back as a bare JSON string sentence.
    final text = json is String ? json.trim() : null;
    final usable = text != null && text.isNotEmpty && !text.startsWith('<');
    return PlezyFinSubtitleDownload(ok: false, message: usable ? text : null, statusCode: statusCode);
  }
}

/// An external subtitle file the server lists on one version of an item,
/// read fresh after a download so the new file can be found and switched on.
class PlezyFinExternalSubtitle {
  /// Stream index: the id the player's source subtitle choice uses.
  final int index;

  /// File path on the server. May be withheld from some accounts.
  final String? path;

  /// As the server reports it (often three letters, "eng").
  final String? language;
  final bool forced;
  final bool hearingImpaired;

  const PlezyFinExternalSubtitle({
    required this.index,
    this.path,
    this.language,
    this.forced = false,
    this.hearingImpaired = false,
  });

  /// External subtitle streams in a raw `MediaSource`'s `MediaStreams`.
  static List<PlezyFinExternalSubtitle> listFromMediaSource(Map<String, dynamic> source) => [
    for (final stream in flexibleMapList(source['MediaStreams']))
      if (stream['Type'] == 'Subtitle' && stream['IsExternal'] == true && flexibleInt(stream['Index']) != null)
        PlezyFinExternalSubtitle(
          index: flexibleInt(stream['Index'])!,
          path: _text(stream, 'Path'),
          language: _text(stream, 'Language'),
          forced: flexibleBool(stream['IsForced']),
          hearingImpaired: flexibleBool(stream['IsHearingImpaired']),
        ),
  ];
}
