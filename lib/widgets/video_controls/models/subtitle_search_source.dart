import '../../../i18n/strings.g.dart';
import '../../../models/plex/plex_subtitle_search_result.dart';
import '../../../models/plezyfin_subtitles.dart';
import '../../../services/jellyfin_client.dart';
import '../../../services/plex_client.dart';
import '../../../utils/app_logger.dart';
import 'track_controls_state.dart';

/// One subtitle a search found, as the search sheet shows it, whatever the
/// server behind it.
class SubtitleSearchHit {
  /// What the source needs to download it.
  final String key;
  final String? title;
  final String? subtitle;
  final int? score;

  /// Made for this exact file (Plex's star).
  final bool perfectMatch;
  final bool forced;
  final bool hearingImpaired;

  /// The backend's own result, handed back to [SubtitleSearchSource.download].
  final Object result;

  const SubtitleSearchHit({
    required this.key,
    required this.result,
    this.title,
    this.subtitle,
    this.score,
    this.perfectMatch = false,
    this.forced = false,
    this.hearingImpaired = false,
  });
}

/// A search answer. With no [hits], the sheet shows [message] (or its own
/// "No subtitles found"); [notes] are short muted lines under the list.
class SubtitleSearchPage {
  final List<SubtitleSearchHit> hits;
  final String? message;
  final List<String> notes;

  const SubtitleSearchPage({required this.hits, this.message, this.notes = const []});
}

/// A download's answer. [message] is shown as is when the download failed;
/// null means the sheet's own failure sentence. [hint] says what was saved,
/// so the player can find the new file.
class SubtitleDownloadResult {
  final bool ok;
  final String? message;
  final DownloadedSubtitleHint? hint;

  const SubtitleDownloadResult({required this.ok, this.message, this.hint});
}

/// Search and download behind the player's subtitle search sheet: Plex's
/// own OpenSubtitles proxy, or PlezyFin's Bazarr routes.
abstract class SubtitleSearchSource {
  /// Plex can search under another title; PlezyFin searches the item itself.
  bool get supportsTitle;

  /// PlezyFin offers the "Forced only" filter (foreign-language parts).
  bool get supportsForcedFilter;

  /// Whether results carry "Forced" / "HI" tags.
  bool get showsTags;

  /// [language] is a two-letter code.
  Future<SubtitleSearchPage> search({required String language, String? title, bool forcedOnly = false});

  Future<SubtitleDownloadResult> download(SubtitleSearchHit hit, {required String language});
}

class PlexSubtitleSearchSource implements SubtitleSearchSource {
  final PlexClient client;
  final String ratingKey;

  const PlexSubtitleSearchSource(this.client, this.ratingKey);

  @override
  bool get supportsTitle => true;

  @override
  bool get supportsForcedFilter => false;

  @override
  bool get showsTags => false;

  @override
  Future<SubtitleSearchPage> search({required String language, String? title, bool forcedOnly = false}) async {
    final results = await client.searchSubtitles(ratingKey, language: language, title: title);
    return SubtitleSearchPage(
      hits: [
        for (final result in results)
          SubtitleSearchHit(
            key: result.key,
            result: result,
            title: result.title ?? result.displayTitle,
            subtitle: result.displayTitle ?? '',
            score: result.score?.toInt(),
            perfectMatch: result.perfectMatch,
            forced: result.forced,
            hearingImpaired: result.hearingImpaired,
          ),
      ],
    );
  }

  @override
  Future<SubtitleDownloadResult> download(SubtitleSearchHit hit, {required String language}) async {
    final result = hit.result as PlexSubtitleSearchResult;
    final ok = await client.downloadSubtitle(
      ratingKey,
      key: result.key,
      codec: result.codec ?? 'srt',
      language: result.languageCode ?? language,
      hearingImpaired: result.hearingImpaired,
      forced: result.forced,
      providerTitle: result.providerTitle ?? '',
    );
    return SubtitleDownloadResult(ok: ok);
  }
}

/// PlezyFin (PLAN_PFN_103): the server searches Bazarr for this item's
/// version [mediaSourceId] and saves the chosen file beside the video.
class PlezyFinSubtitleSearchSource implements SubtitleSearchSource {
  final JellyfinClient client;
  final String itemId;
  final String? mediaSourceId;

  const PlezyFinSubtitleSearchSource(this.client, this.itemId, {this.mediaSourceId});

  @override
  bool get supportsTitle => false;

  @override
  bool get supportsForcedFilter => true;

  @override
  bool get showsTags => true;

  @override
  Future<SubtitleSearchPage> search({required String language, String? title, bool forcedOnly = false}) async {
    final answer = await client.searchSubtitlesViaServer(
      itemId,
      mediaSourceId: mediaSourceId,
      language: language,
      // Off means "any", not "not forced".
      forced: forcedOnly ? true : null,
    );
    final hits = [
      for (final result in answer.results)
        SubtitleSearchHit(
          key: result.id,
          result: result,
          title: result.release ?? result.provider,
          subtitle: [?result.provider, ?result.uploader].join(' · '),
          score: result.score,
          forced: result.forced,
          hearingImpaired: result.hearingImpaired,
        ),
    ];
    final message = answer.ok ? null : answer.message;
    return SubtitleSearchPage(
      hits: hits,
      message: message,
      notes: [
        // A refusal sentence that came with results still gets said.
        if (hits.isNotEmpty && message != null) message,
        for (final provider in answer.unavailable) provider.summary,
      ],
    );
  }

  @override
  Future<SubtitleDownloadResult> download(SubtitleSearchHit hit, {required String language}) async {
    final result = hit.result as PlezyFinSubtitleResult;
    // What is there now, so the player can tell the new file from the old
    // ones afterwards: Jellyfin lists external files first, so stream ids
    // shift when one is added. Best effort; the finder copes without it.
    List<PlezyFinExternalSubtitle>? filesBefore;
    try {
      filesBefore = await client.fetchExternalSubtitleFiles(itemId, mediaSourceId: mediaSourceId);
    } catch (e) {
      appLogger.w('PlezyFin subtitle download: could not list the files before it', error: e);
    }
    final answer = await client.downloadSubtitleViaServer(result.id, itemId: itemId);
    if (!answer.ok) {
      return SubtitleDownloadResult(
        ok: false,
        message: answer.message ?? (answer.statusCode == 403 ? t.videoControls.subtitleDownloadNotAllowed : null),
      );
    }
    return SubtitleDownloadResult(
      ok: true,
      hint: DownloadedSubtitleHint(
        languageCode: result.language ?? language,
        forced: result.forced,
        hearingImpaired: result.hearingImpaired,
        format: result.format,
        filesBefore: filesBefore,
      ),
    );
  }
}
