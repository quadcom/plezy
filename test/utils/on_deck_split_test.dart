import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/utils/on_deck_split.dart';

import '../test_helpers/media_items.dart';

/// Adrian, 2026-10-09: his home showed no Continue Watching because the 20
/// most recent on-deck items were all Next Up episodes.
void main() {
  final nextUp = [for (var i = 0; i < 5; i++) testMediaItem(id: 'n$i', kind: MediaKind.episode)];
  final started = [for (var i = 0; i < 3; i++) testMediaItem(id: 's$i', viewOffsetMs: 1000)];

  test('the limit applies to started items and the rest separately, keeping order', () {
    final items = [...nextUp, ...started];
    final limited = limitOnDeckPerKind(items, 2);
    expect([for (final item in limited) item.id], ['n0', 'n1', 's0', 's1']);
    expect(exceedsOnDeckPerKind(items, 2), isTrue);
    expect(exceedsOnDeckPerKind(items, 5), isFalse);
    expect(limitOnDeckPerKind(items, null), same(items));
  });
}
