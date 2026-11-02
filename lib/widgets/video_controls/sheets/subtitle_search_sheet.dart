import 'dart:async';
import '../../../media/ids.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_button.dart';
import '../../../focus/focusable_text_field.dart';
import '../../../focus/input_mode_tracker.dart';
import '../../../i18n/strings.g.dart';
import '../../../mixins/controller_disposer_mixin.dart';
import '../../../services/jellyfin_client.dart';
import '../../../services/plex_client.dart';
import '../../../services/settings_service.dart';
import '../../../utils/language_codes.dart';
import '../../../utils/provider_extensions.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../widgets/pill_input_decoration.dart';
import 'base_video_control_sheet.dart';
import '../../loading_indicator_box.dart';
import '../models/subtitle_search_source.dart';
import '../models/track_controls_state.dart';

@visibleForTesting
String resolveSubtitleSearchLanguageCode({String? savedLanguageCode, required Locale systemLocale}) {
  return LanguageCodes.getIso6391Code(savedLanguageCode ?? '') ??
      LanguageCodes.getIso6391Code(systemLocale.languageCode) ??
      'en';
}

class SubtitleSearchSheet extends StatefulWidget {
  final String ratingKey;
  final String serverId;
  final String? mediaTitle;

  /// The version playing, for a PlezyFin search. Null on Plex.
  final String? mediaSourceId;
  final SubtitleDownloadedCallback? onSubtitleDownloaded;

  /// Search and download behind the sheet. Null picks it from [serverId]'s
  /// client: Plex's own search, or PlezyFin's.
  final SubtitleSearchSource? source;

  const SubtitleSearchSheet({
    super.key,
    required this.ratingKey,
    required this.serverId,
    this.mediaTitle,
    this.mediaSourceId,
    this.onSubtitleDownloaded,
    this.source,
  });

  @override
  State<SubtitleSearchSheet> createState() => _SubtitleSearchSheetState();
}

class _SubtitleSearchSheetState extends State<SubtitleSearchSheet> with ControllerDisposerMixin {
  String _languageCode = 'en';
  String _languageName = 'English';
  late final _titleController = createTextEditingController();
  final _languageFocusNode = FocusNode(debugLabel: 'SubtitleSearch_language');
  final _titleFocusNode = FocusNode(debugLabel: 'SubtitleSearch_title');
  final _forcedFocusNode = FocusNode(debugLabel: 'SubtitleSearch_forced');
  final _firstResultFocusNode = FocusNode(debugLabel: 'SubtitleSearch_firstResult');
  Timer? _debounceTimer;

  SubtitleSearchSource? _source;
  bool _sourceResolved = false;
  bool _forcedOnly = false;

  List<SubtitleSearchHit>? _results;
  String? _message;
  List<String> _notes = const [];
  bool _isSearching = false;
  String? _error;
  String? _downloadingKey;
  int _searchGeneration = 0;

  bool _showLanguagePicker = false;

  @override
  void initState() {
    super.initState();
    _initDefaultLanguage();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  void _initDefaultLanguage() {
    final code = resolveSubtitleSearchLanguageCode(
      savedLanguageCode: SettingsService.instanceOrNull?.read(SettingsService.subtitleSearchLanguage),
      systemLocale: WidgetsBinding.instance.platformDispatcher.locale,
    );
    final name = LanguageCodes.getLanguageName(code);
    if (name == null) return;
    _languageCode = code;
    _languageName = name;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sourceResolved) return;
    _sourceResolved = true;
    _source = widget.source ?? _sourceFromClient();
  }

  SubtitleSearchSource? _sourceFromClient() {
    final client = context.tryGetMediaClientForServer(ServerId(widget.serverId));
    return switch (client) {
      PlexClient() => PlexSubtitleSearchSource(client, widget.ratingKey),
      JellyfinClient() => PlezyFinSubtitleSearchSource(client, widget.ratingKey, mediaSourceId: widget.mediaSourceId),
      _ => null,
    };
  }

  /// No source yet (no client) keeps Plex's layout, title box included.
  bool get _showsTitle => _source?.supportsTitle ?? true;
  bool get _showsForcedFilter => _source?.supportsForcedFilter ?? false;

  @override
  void dispose() {
    ++_searchGeneration;
    _debounceTimer?.cancel();
    _languageFocusNode.dispose();
    _titleFocusNode.dispose();
    _forcedFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (!mounted) return;
    final generation = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      _error = null;
    });

    try {
      final source = _source;
      if (source == null) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() => _isSearching = false);
        return;
      }
      final title = _titleController.text.trim();
      final page = await source.search(
        language: _languageCode,
        title: source.supportsTitle && title.isNotEmpty ? title : null,
        forcedOnly: source.supportsForcedFilter && _forcedOnly,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = page.hits;
        _message = page.message;
        _notes = page.notes;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _error = e.toString();
        _isSearching = false;
      });
    }
  }

  void _onTitleChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _search);
  }

  void _toggleForcedOnly() {
    _debounceTimer?.cancel();
    setState(() => _forcedOnly = !_forcedOnly);
    _search();
  }

  void _showLanguagePickerView() {
    setState(() => _showLanguagePicker = true);
    OverlaySheetController.of(context).refocus();
  }

  void _hideLanguagePickerView() {
    setState(() => _showLanguagePicker = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _languageFocusNode.requestFocus();
    });
  }

  void _focusFirstResult() {
    if (_results != null && _results!.isNotEmpty && !_isSearching && _error == null) {
      _firstResultFocusNode.requestFocus();
    }
  }

  Future<void> _submitSearchAndFocusFirstResult() async {
    _debounceTimer?.cancel();
    await _search();
    if (!mounted || !InputModeTracker.isKeyboardMode(context, listen: false)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusFirstResult();
    });
  }

  void _onLanguageSelected(String code, String name) {
    _debounceTimer?.cancel();
    setState(() {
      _languageCode = code;
      _languageName = name;
      _showLanguagePicker = false;
    });
    final settings = SettingsService.instanceOrNull;
    if (settings != null) {
      unawaited(settings.write(SettingsService.subtitleSearchLanguage, code));
    }
    OverlaySheetController.of(context).refocus();
    _search();
  }

  Future<void> _downloadSubtitle(SubtitleSearchHit hit) async {
    if (_downloadingKey != null) return;
    setState(() => _downloadingKey = hit.key);

    try {
      final source = _source;
      if (source == null) {
        if (!mounted) return;
        setState(() => _downloadingKey = null);
        return;
      }
      final download = await source.download(hit, language: _languageCode);

      if (!mounted) return;

      if (download.ok) {
        final outcome =
            await widget.onSubtitleDownloaded?.call(
              serverId: widget.serverId,
              ratingKey: widget.ratingKey,
              hint: download.hint,
            ) ??
            SubtitleDownloadApplyOutcome.unavailable;
        if (!mounted) return;
        if (outcome == SubtitleDownloadApplyOutcome.applied) {
          showSuccessSnackBar(context, t.videoControls.subtitleDownloaded);
          OverlaySheetController.of(context).close();
        } else {
          showErrorSnackBar(context, t.videoControls.subtitleDownloadedNotApplied);
          setState(() => _downloadingKey = null);
        }
      } else {
        // The server's own sentence when it gave one (daily limit, an id
        // older than 30 minutes, not allowed).
        showErrorSnackBar(context, download.message ?? t.videoControls.subtitleDownloadFailed);
        setState(() => _downloadingKey = null);
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
      setState(() => _downloadingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showLanguagePicker) {
      return _LanguagePickerView(
        currentCode: _languageCode,
        onSelected: _onLanguageSelected,
        onBack: _hideLanguagePickerView,
      );
    }

    final fillColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    final hasResults = _results != null && _results!.isNotEmpty && !_isSearching && _error == null;

    return BaseVideoControlSheet(
      title: t.videoControls.searchSubtitles,
      icon: Symbols.search_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      // Deliberately fills the sheet's height cap instead of hugging content.
      // Overlay sheets are bottom-anchored, so a content-driven height would
      // move the search field on every state transition — spinner, results,
      // error, empty — while the user is still typing in it. A search surface
      // needs a stable frame; the results list normally fills it anyway.
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FocusableButton(
                  focusNode: _languageFocusNode,
                  onPressed: _showLanguagePickerView,
                  onNavigateRight: _showsTitle
                      ? _titleFocusNode.requestFocus
                      : (_showsForcedFilter ? _forcedFocusNode.requestFocus : null),
                  onNavigateDown: hasResults ? _focusFirstResult : null,
                  autoScroll: false,
                  child: Material(
                    color: fillColor,
                    borderRadius: pillInputRadius,
                    child: InkWell(
                      borderRadius: pillInputRadius,
                      canRequestFocus: false,
                      onTap: _showLanguagePickerView,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          mainAxisSize: .min,
                          children: [
                            Text(_languageName),
                            const SizedBox(width: 2),
                            const AppIcon(Symbols.arrow_drop_down_rounded, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (_showsForcedFilter) _buildForcedToggle(fillColor, hasResults),
                if (_showsTitle)
                  Expanded(
                    child: FocusableTextField(
                      controller: _titleController,
                      focusNode: _titleFocusNode,
                      tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
                      decoration: pillInputDecoration(
                        context,
                        hintText: widget.mediaTitle ?? t.metadataEdit.title,
                        prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
                      ),
                      onChanged: _onTitleChanged,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => unawaited(_submitSearchAndFocusFirstResult()),
                      onSelect: () => unawaited(_submitSearchAndFocusFirstResult()),
                      onNavigateLeft: _languageFocusNode.requestFocus,
                      onNavigateDown: hasResults ? _focusFirstResult : null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _buildResults()),
          if (_notes.isNotEmpty && !_isSearching && _error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  for (final note in _notes)
                    Text(note, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// PlezyFin's "Forced only" filter: subtitles for just the foreign-language
  /// parts. Off searches everything.
  Widget _buildForcedToggle(Color fillColor, bool hasResults) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = _forcedOnly ? colorScheme.primary : null;
    return Semantics(
      toggled: _forcedOnly,
      child: FocusableButton(
        focusNode: _forcedFocusNode,
        onPressed: _toggleForcedOnly,
        onNavigateLeft: _languageFocusNode.requestFocus,
        onNavigateDown: hasResults ? _focusFirstResult : null,
        autoScroll: false,
        child: Material(
          color: fillColor,
          borderRadius: pillInputRadius,
          child: InkWell(
            borderRadius: pillInputRadius,
            canRequestFocus: false,
            onTap: _toggleForcedOnly,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: .min,
                children: [
                  AppIcon(
                    _forcedOnly ? Symbols.check_box_rounded : Symbols.check_box_outline_blank_rounded,
                    fill: _forcedOnly ? 1 : 0,
                    size: 20,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Text(t.videoControls.forcedOnly, style: TextStyle(color: color)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }

    if (_results == null) {
      return const SizedBox.shrink();
    }

    if (_results!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _message ?? t.videoControls.noSubtitlesFound,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final showsTags = _source?.showsTags ?? false;

    return ListView.builder(
      itemCount: _results!.length,
      itemBuilder: (context, index) {
        final result = _results![index];
        final isDownloading = _downloadingKey == result.key;
        final colorScheme = Theme.of(context).colorScheme;

        Widget? trailing;
        if (isDownloading) {
          trailing = const LoadingIndicatorBox(size: 20);
        } else {
          final trailingChildren = <Widget>[
            if (showsTags && result.forced) _ResultTag(t.videoControls.subtitleTagForced),
            if (showsTags && result.hearingImpaired) _ResultTag(t.videoControls.subtitleTagHearingImpaired),
          ];
          if (result.perfectMatch) {
            trailingChildren.add(const AppIcon(Symbols.star_rounded, fill: 1, color: Color(0xFFCC7B19), size: 16));
          }
          if (result.score != null) {
            trailingChildren.add(
              Text(result.score!.toString(), style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
            );
          }
          if (trailingChildren.isNotEmpty) {
            trailing = Row(mainAxisSize: .min, spacing: 4, children: trailingChildren);
          }
        }

        return FocusableListTile(
          focusNode: index == 0 ? _firstResultFocusNode : null,
          title: Text(result.title ?? t.common.unknown, maxLines: 1, overflow: .ellipsis),
          subtitle: Text(
            result.subtitle ?? '',
            maxLines: 1,
            overflow: .ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          trailing: trailing,
          onTap: isDownloading ? null : () => _downloadSubtitle(result),
        );
      },
    );
  }
}

/// A small "Forced" / "HI" label beside a result's score.
class _ResultTag extends StatelessWidget {
  final String label;

  const _ResultTag(this.label);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
    );
  }
}

class _LanguagePickerView extends StatefulWidget {
  final String currentCode;
  final void Function(String code, String name) onSelected;
  final VoidCallback onBack;

  const _LanguagePickerView({required this.currentCode, required this.onSelected, required this.onBack});

  @override
  State<_LanguagePickerView> createState() => _LanguagePickerViewState();
}

class _LanguagePickerViewState extends State<_LanguagePickerView> with ControllerDisposerMixin {
  late final _filterController = createTextEditingController();
  final _filterFocusNode = FocusNode(debugLabel: 'SubtitleLanguage_filter');
  final _firstLanguageFocusNode = FocusNode(debugLabel: 'SubtitleLanguage_firstResult');
  late List<({String code, String name})> _allLanguages;
  List<({String code, String name})> _filteredLanguages = [];

  @override
  void initState() {
    super.initState();
    _allLanguages = LanguageCodes.getAllLanguages();
    _filteredLanguages = _allLanguages;
  }

  @override
  void dispose() {
    _filterFocusNode.dispose();
    _firstLanguageFocusNode.dispose();
    super.dispose();
  }

  void _focusFirstLanguage() {
    if (_filteredLanguages.isNotEmpty) {
      _firstLanguageFocusNode.requestFocus();
    }
  }

  void _focusFirstLanguageAfterSubmit() {
    if (!InputModeTracker.isKeyboardMode(context)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusFirstLanguage();
    });
  }

  void _onFilterChanged(String query) {
    final lower = query.toLowerCase();
    setState(() {
      if (lower.isEmpty) {
        _filteredLanguages = _allLanguages;
      } else {
        _filteredLanguages = _allLanguages.where((l) {
          return l.name.toLowerCase().contains(lower) || l.code.toLowerCase().contains(lower);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BaseVideoControlSheet(
      title: t.videoControls.language,
      icon: Symbols.language_rounded,
      onBack: widget.onBack,
      // Fills the height cap for the same reason as the search body: the filter
      // field is autofocused and refilters on every keystroke, so a
      // content-driven height would slide the field the user is typing in.
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FocusableTextField(
              controller: _filterController,
              focusNode: _filterFocusNode,
              tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
              autofocus: true,
              decoration: pillInputDecoration(
                context,
                hintText: t.videoControls.searchLanguages,
                prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
              ),
              onChanged: _onFilterChanged,
              onSubmitted: (_) => _focusFirstLanguageAfterSubmit(),
              onSelect: _focusFirstLanguageAfterSubmit,
              onNavigateDown: _filteredLanguages.isNotEmpty ? _focusFirstLanguage : null,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredLanguages.length,
              itemBuilder: (context, index) {
                final lang = _filteredLanguages[index];
                final isSelected = lang.code == widget.currentCode;
                return FocusableListTile(
                  focusNode: index == 0 ? _firstLanguageFocusNode : null,
                  title: Text(
                    lang.name,
                    style: TextStyle(color: isSelected ? Theme.of(context).colorScheme.primary : null),
                  ),
                  trailing: isSelected
                      ? AppIcon(Symbols.check_rounded, fill: 1, color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => widget.onSelected(lang.code, lang.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
