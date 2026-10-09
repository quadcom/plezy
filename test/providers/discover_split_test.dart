import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/discover_provider.dart';

import '../test_helpers/media_items.dart';

/// Continue Watching and Next Up are two rows since 2026-10-09 (Adrian).
void main() {
  test('started items go to Continue Watching, the rest to Next Up, each in order', () {
    final started = testMediaItem(id: 'a', kind: MediaKind.episode, durationMs: 1000, viewOffsetMs: 300);
    final next = testMediaItem(id: 'b', kind: MediaKind.episode, durationMs: 1000);
    final movie = testMediaItem(id: 'c', durationMs: 5000, viewOffsetMs: 10);
    final finished = testMediaItem(id: 'd', kind: MediaKind.episode, durationMs: 1000, viewOffsetMs: 1000);

    final split = DiscoverProvider.splitOnDeck([started, next, movie, finished]);

    expect([for (final item in split.resume) item.id], ['a', 'c']);
    expect([for (final item in split.nextUp) item.id], ['b', 'd']);
  });
}
