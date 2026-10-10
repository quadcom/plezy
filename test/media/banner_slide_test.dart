import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/banner_slide.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';

BannerSlide _slide(String id, BannerKind kind) => BannerSlide(
  MediaItem(id: id, backend: MediaBackend.jellyfin, kind: MediaKind.movie, title: id, serverId: 'srv'),
  kind,
);

void main() {
  test('upcoming slides land on every fourth slide, 20 in all', () {
    final fresh = [for (var i = 0; i < 20; i++) _slide('n$i', BannerKind.newMovie)];
    final upcoming = [for (var i = 0; i < 10; i++) _slide('u$i', BannerKind.comingSoon)];

    final deck = interleaveBanner(fresh, upcoming);

    expect(deck, hasLength(20));
    for (var slot = 1; slot <= 20; slot++) {
      expect(deck[slot - 1].isUpcoming, slot % 4 == 0, reason: 'slide $slot');
    }
  });

  test('a short list closes up; nothing is padded', () {
    final deck = interleaveBanner(
      [_slide('n0', BannerKind.newEpisode), _slide('n1', BannerKind.newMovie)],
      [for (var i = 0; i < 3; i++) _slide('u$i', BannerKind.newShow)],
    );
    expect([for (final s in deck) s.item.id], ['n0', 'n1', 'u0', 'u1', 'u2']);
    expect(interleaveBanner(const [], const []), isEmpty);
  });

  test('an upcoming slide reads its release date', () {
    final slide = BannerSlide(
      MediaItem.jellyfin(id: 'soon', kind: MediaKind.movie, title: 'Soon', originallyAvailableAt: '2026-10-28'),
      BannerKind.comingSoon,
    );
    expect(slide.releaseDate, DateTime(2026, 10, 28));
    expect(slide.isUpcoming, isTrue);
  });
}
