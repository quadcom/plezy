/// How long each start-up step took in this run (local/plans/dev-tools.md).
///
/// Always recorded: a few dozen small entries, kept in memory only. Read by
/// the developer tools (`startup.timeline`), which run in developer mode.
class StartupTimeline {
  StartupTimeline._();

  static final Stopwatch _clock = Stopwatch();
  static DateTime? _startedAt;
  static final List<({String name, int atMs, int? tookMs})> _entries = [];
  static const _maxEntries = 200;

  /// Called first thing in `main()`.
  static void start() {
    if (_clock.isRunning) return;
    _startedAt = DateTime.now();
    _clock.start();
    _entries.clear();
  }

  /// A point in start-up, such as a phase finishing.
  static void mark(String name) => _add(name, null);

  /// Runs [action] and records how long it took.
  static Future<T> time<T>(String name, Future<T> Function() action) async {
    final from = _clock.elapsedMilliseconds;
    try {
      return await action();
    } finally {
      _add(name, _clock.elapsedMilliseconds - from, atMs: from);
    }
  }

  static void _add(String name, int? tookMs, {int? atMs}) {
    if (!_clock.isRunning) start();
    if (_entries.length >= _maxEntries) return;
    _entries.add((name: name, atMs: atMs ?? _clock.elapsedMilliseconds, tookMs: tookMs));
  }

  static Map<String, dynamic> toJson() => {
    'startedAt': _startedAt?.toIso8601String(),
    'entries': [
      for (final e in _entries) {'name': e.name, 'atMs': e.atMs, if (e.tookMs != null) 'tookMs': e.tookMs},
    ],
  };

  static void debugReset() {
    _clock
      ..stop()
      ..reset();
    _startedAt = null;
    _entries.clear();
  }
}
