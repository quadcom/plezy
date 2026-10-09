import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_course.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../media/media_trailer.dart';
import '../../utils/app_logger.dart';
import '../../utils/formatters.dart';
import '../../utils/platform_detector.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/video_player_navigation.dart';
import '../../widgets/app_bar_back_button.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/cycling_media_backdrop.dart';
import '../../widgets/media_rail/rail_parts.dart';
import '../../widgets/optimized_media_image.dart';

/// A Master Class course (see `media_course.dart`) laid out the way
/// MasterClass presents one: who teaches what, the course's progress, its
/// lessons in a rail, and the selected lesson's notes. Fork-only; the design
/// is in `local/plans/masterclass-course-screen.md`.
///
/// The background cycles through the lesson stills, since courses carry no
/// fan art. Lessons play through the normal player, so the next lesson
/// follows the Auto-Play Next Episode and Play Next Countdown settings.
class CourseDetailScreen extends StatefulWidget {
  const CourseDetailScreen({super.key, required this.metadata, this.initialLessonId});

  /// The course (a show), or one of its seasons.
  final MediaItem metadata;

  /// Lesson to select first, e.g. when opened from that lesson.
  final String? initialLessonId;

  @override
  State<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends State<CourseDetailScreen> {
  static const _stillInterval = Duration(seconds: 9);
  static const _stillFade = Duration(milliseconds: 2500);

  late MediaItem _course = widget.metadata;
  List<MediaItem> _lessons = const [];
  MediaItem? _onDeck;
  MediaItem? _trailer;
  bool _loading = true;
  bool _failed = false;
  int _selected = 0;
  bool _firstLoad = true;

  final _primaryFocus = FocusNode(debugLabel: 'Course:Primary');
  final List<FocusNode> _lessonFocus = [];

  String get _courseId =>
      widget.metadata.kind == MediaKind.season ? (widget.metadata.parentId ?? widget.metadata.id) : widget.metadata.id;

  MediaServerClient? get _client => context.tryGetMediaClientForServer(serverIdOrNull(widget.metadata.serverId));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _primaryFocus.dispose();
    for (final node in _lessonFocus) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    try {
      final (detail, descendants, extras) = await (
        client.fetchItemWithOnDeck(_courseId),
        client.fetchPlayableDescendants(_courseId),
        _fetchExtras(client),
      ).wait;
      if (!mounted) return;
      final course = detail.item ?? _course;
      final lessons = [
        for (final lesson in descendants)
          lesson.copyWith(
            serverId: lesson.serverId ?? course.serverId ?? widget.metadata.serverId,
            serverName: lesson.serverName ?? course.serverName ?? widget.metadata.serverName,
            libraryId: lesson.libraryId ?? course.libraryId,
            libraryTitle: lesson.libraryTitle ?? course.libraryTitle,
          ),
      ]..sort(_lessonOrder);
      final trailer = pickTrailer(course, extras)?.copyWith(
        serverId: course.serverId ?? widget.metadata.serverId,
        serverName: course.serverName ?? widget.metadata.serverName,
      );
      setState(() {
        _course = course;
        _lessons = lessons;
        _onDeck = detail.onDeckEpisode;
        _trailer = trailer;
        _selected = _firstLoad
            ? _initialSelection(lessons)
            : _selected.clamp(0, lessons.isEmpty ? 0 : lessons.length - 1);
        _loading = false;
        _failed = false;
        _syncLessonFocus(lessons.length);
      });
      if (_firstLoad) {
        _firstLoad = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _primaryFocus.requestFocus();
        });
      }
    } catch (e, st) {
      appLogger.w('Course ${widget.metadata.id} failed to load', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = _lessons.isEmpty;
      });
    }
  }

  /// The course's extras, where PMB puts its trailer. A course without them
  /// (or a server that fails to list them) just shows no trailer button.
  Future<List<MediaItem>> _fetchExtras(MediaServerClient client) async {
    try {
      return await client.fetchExtras(_courseId);
    } catch (e) {
      appLogger.d('Course $_courseId extras failed to load', error: e);
      return const [];
    }
  }

  static int _lessonOrder(MediaItem a, MediaItem b) {
    final season = (a.parentIndex ?? 0).compareTo(b.parentIndex ?? 0);
    return season != 0 ? season : (a.index ?? 0).compareTo(b.index ?? 0);
  }

  int _initialSelection(List<MediaItem> lessons) {
    if (lessons.isEmpty) return 0;
    final wanted = widget.initialLessonId;
    if (wanted != null) {
      final i = lessons.indexWhere((l) => l.id == wanted);
      if (i >= 0) return i;
    }
    final resume = _resumeIndex(lessons, _onDeck);
    return resume ?? 0;
  }

  /// The lesson to resume: the server's on-deck lesson, else the first one not
  /// yet watched. Null when every lesson has been watched.
  static int? _resumeIndex(List<MediaItem> lessons, MediaItem? onDeck) {
    if (onDeck != null) {
      final i = lessons.indexWhere((l) => l.id == onDeck.id);
      if (i >= 0) return i;
    }
    final i = lessons.indexWhere((l) => !l.isWatched);
    return i >= 0 ? i : null;
  }

  void _syncLessonFocus(int count) {
    while (_lessonFocus.length < count) {
      _lessonFocus.add(FocusNode(debugLabel: 'Course:Lesson${_lessonFocus.length + 1}'));
    }
    while (_lessonFocus.length > count) {
      _lessonFocus.removeLast().dispose();
    }
  }

  Future<void> _play(MediaItem lesson) async {
    await navigateToVideoPlayerWithRefresh(
      context,
      metadata: lesson,
      onRefresh: () => unawaited(_load()),
      isLaunchCurrent: () => mounted,
    );
  }

  int get _watchedCount => _lessons.where((l) => l.isWatched).length;

  bool get _started => _lessons.any((l) => l.isWatched || (l.viewOffsetMs ?? 0) > 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = _client;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final stills = [
            for (final lesson in _lessons)
              if (lesson.thumbPath?.isNotEmpty == true) lesson.thumbPath!,
          ];
          return Stack(
            children: [
              Positioned.fill(
                child: CyclingMediaBackdrop(
                  mediaKey: '${_course.globalKey}:${stills.length}',
                  imagePaths: stills,
                  fallbackImagePaths: [if (_course.thumbPath != null) _course.thumbPath!],
                  client: client,
                  width: size.width,
                  height: size.height,
                  fallbackColor: theme.colorScheme.surface,
                  rotationInterval: _stillInterval,
                  fadeDuration: _stillFade,
                ),
              ),
              Positioned.fill(child: RailScrim(color: theme.colorScheme.surface)),
              SafeArea(child: _buildBody(context, client, size)),
              if (!PlatformDetector.isTV())
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: AppBarBackButton(onPressed: () => Navigator.pop(context)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, MediaServerClient? client, Size size) {
    final theme = Theme.of(context);
    if (_loading && _lessons.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(child: Text(t.course.loadFailed, style: theme.textTheme.titleMedium));
    }
    final wide = size.width >= 700;
    final pad = EdgeInsets.fromLTRB(wide ? 48 : 20, wide ? 40 : 56, wide ? 48 : 20, 32);
    final summary = courseSummary(_course.summary);
    return SingleChildScrollView(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, client, size, wide),
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Text(
                summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.85)),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            t.course.lessons,
            style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 10),
          _buildRail(context, client, size, wide),
          if (_lessons.isNotEmpty) ...[const SizedBox(height: 16), _buildNotes(context)],
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, MediaServerClient? client, Size size, bool wide) {
    final theme = Theme.of(context);
    final title = splitCourseTitle(_course.title ?? '', instructors: _course.courseInstructors);
    final posterWidth = wide ? (size.width * 0.13).clamp(84.0, 200.0) : (size.width * 0.36).clamp(110.0, 170.0);
    final totalMs = _lessons.fold<int>(0, (sum, l) => sum + (l.durationMs ?? 0));
    final meta = [
      if (_course.year != null) '${_course.year}',
      t.course.lessonCount(n: _lessons.length),
      if (totalMs > 0) formatDurationTextual(totalMs),
    ].join('  ·  ');

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title.instructor.isNotEmpty)
          Text(
            title.instructor.toUpperCase(),
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          title.subject,
          style: (wide ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          meta,
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
        ),
        if (_lessons.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _watchedCount / _lessons.length,
              minHeight: 5,
              backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t.course.lessonsWatched(watched: _watchedCount, total: _lessons.length),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
          ),
        ],
        if (wide) ...[const SizedBox(height: 14), _buildButtons(context)],
      ],
    );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: posterWidth,
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: OptimizedMediaImage.poster(client: client, imagePath: _course.thumbPath),
            ),
          ),
        ),
        SizedBox(width: wide ? 32 : 16),
        Expanded(child: info),
      ],
    );
    if (wide) return row;
    // On a phone the buttons get the full width below, so the poster can grow.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [row, const SizedBox(height: 16), _buildButtons(context)],
    );
  }

  Widget _buildButtons(BuildContext context) {
    final trailer = _trailer;
    if (_lessons.isEmpty && trailer == null) return const SizedBox.shrink();
    final resume = _resumeIndex(_lessons, _onDeck);
    final started = _started;
    final target = _lessons.isEmpty ? null : _lessons[resume ?? 0];
    final label = started && resume != null && target != null
        ? t.course.resumeLesson(number: target.index ?? resume + 1, title: target.title ?? '')
        : t.course.startCourse;
    void playPrimary() => unawaited(_play(target!));
    void startOver() => unawaited(_play(_lessons.first.copyWith(viewOffsetMs: 0)));
    void playTrailer() => unawaited(navigateToVideoPlayer(context, metadata: trailer!, isLaunchCurrent: () => mounted));
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        if (target != null)
          FocusableButton(
            focusNode: _primaryFocus,
            useBackgroundFocus: true,
            onPressed: playPrimary,
            onNavigateDown: _focusSelectedLesson,
            child: FilledButton.icon(
              onPressed: playPrimary,
              icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
              label: Text(label, overflow: TextOverflow.ellipsis),
            ),
          ),
        if (started)
          FocusableButton(
            useBackgroundFocus: true,
            onPressed: startOver,
            onNavigateDown: _focusSelectedLesson,
            child: OutlinedButton.icon(
              onPressed: startOver,
              icon: const AppIcon(Symbols.replay_rounded, fill: 1),
              label: Text(t.course.startOver),
            ),
          ),
        if (trailer != null)
          FocusableButton(
            focusNode: target == null ? _primaryFocus : null,
            useBackgroundFocus: true,
            onPressed: playTrailer,
            onNavigateDown: _focusSelectedLesson,
            child: OutlinedButton.icon(
              onPressed: playTrailer,
              icon: const AppIcon(Symbols.theaters_rounded, fill: 1),
              label: Text(t.course.watchTrailer),
            ),
          ),
      ],
    );
  }

  void _focusSelectedLesson() {
    if (_selected < _lessonFocus.length) _lessonFocus[_selected].requestFocus();
  }

  Widget _buildRail(BuildContext context, MediaServerClient? client, Size size, bool wide) {
    final cardWidth = (size.width * (wide ? 0.2 : 0.55)).clamp(150.0, 320.0);
    final stillHeight = cardWidth * 9 / 16;
    return SizedBox(
      height: stillHeight + 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _lessons.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) => RailItemCard(
          item: _lessons[i],
          badge: '${_lessons[i].index ?? i + 1}',
          semanticLabel: t.course.lessonHeading(number: _lessons[i].index ?? i + 1, title: _lessons[i].title ?? ''),
          onRefresh: (_) => unawaited(_load()),
          onListRefresh: () => unawaited(_load()),
          client: client,
          width: cardWidth,
          selected: i == _selected,
          focusNode: i < _lessonFocus.length ? _lessonFocus[i] : null,
          onFocused: () {
            // Remote and keyboard focus picks the lesson. A tap focuses too,
            // but that is left to onSelect so it doesn't count as two taps.
            if (InputModeTracker.currentMode != InputMode.keyboard) return;
            if (_selected != i) setState(() => _selected = i);
          },
          onNavigateUp: () => _primaryFocus.requestFocus(),
          onSelect: () {
            // Remote and keyboard: focus already picked the lesson, so OK plays
            // it. Touch and mouse: the first tap picks it (its notes show below),
            // a second tap plays it.
            if (InputModeTracker.currentMode == InputMode.keyboard || _selected == i) {
              if (_selected != i) setState(() => _selected = i);
              unawaited(_play(_lessons[i]));
            } else {
              setState(() => _selected = i);
            }
          },
        ),
      ),
    );
  }

  Widget _buildNotes(BuildContext context) {
    final lesson = _lessons[_selected];
    final minutes = lesson.durationMs == null ? null : formatDurationTextual(lesson.durationMs!);
    final heading = t.course.lessonHeading(number: lesson.index ?? _selected + 1, title: lesson.title ?? '');
    return RailNotesPanel(heading: minutes == null ? heading : '$heading  ·  $minutes', body: lesson.summary);
  }
}
