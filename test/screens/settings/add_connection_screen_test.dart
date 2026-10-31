import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focusable_wrapper.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/screens/settings/add_connection_screen.dart';
import 'package:plezy/screens/settings/add_jellyfin_screen.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/backend_badge.dart';

/// The "Add connection" picker is the only route to a new server. Plezy signs
/// in to PlezyFin only (Adrian, 2026-10-31): no Plex, no Emby.
void main() {
  Widget app(Widget home) => MaterialApp(
    theme: monoTheme(dark: true),
    home: InputModeTracker(child: home),
  );

  Profile profile(String id) =>
      Profile.local(id: id, displayName: id, sortOrder: 0, createdAt: DateTime.fromMillisecondsSinceEpoch(0));

  testWidgets('offers PlezyFin only, with its badge', (tester) async {
    await tester.pumpWidget(app(const AddConnectionScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Connect to PlezyFin'), findsOneWidget);
    expect(find.text('Sign in with Plex'), findsNothing);
    expect(find.text('Connect to Emby'), findsNothing);

    final badges = tester.widgetList<BackendBadge>(find.byType(BackendBadge)).map((b) => b.backend).toList();
    expect(badges, <MediaBackend>[MediaBackend.jellyfin]);
  });

  /// The pushed sign-in screen starts a 2s LAN discovery sweep and a
  /// platform package-info read, neither of which settles under
  /// `pumpAndSettle`. Bounded frames are enough: the route's widget exists as
  /// soon as the push completes.
  Future<AddJellyfinScreen> tapCard(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return tester.widget<AddJellyfinScreen>(find.byType(AddJellyfinScreen));
  }

  testWidgets('the PlezyFin card opens the Jellyfin dialect', (tester) async {
    await tester.pumpWidget(app(const AddConnectionScreen()));
    await tester.pumpAndSettle();

    final screen = await tapCard(tester, 'Connect to PlezyFin');
    expect(screen.dialect, MediaBrowserDialect.jellyfin);
    expect(screen.targetProfile, isNull);
    expect(find.text('Add PlezyFin server'), findsOneWidget);
  });

  testWidgets('a scoped picker names the profile and offers borrowing', (tester) async {
    final target = profile('Living Room');
    await tester.pumpWidget(app(AddConnectionScreen(targetProfile: target)));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to your PlezyFin server. Binds to Living Room.'), findsOneWidget);
    expect(find.byType(FocusableWrapper), findsNWidgets(2));

    final screen = await tapCard(tester, 'Connect to PlezyFin');
    expect(screen.dialect, MediaBrowserDialect.jellyfin);
    expect(screen.targetProfile?.id, target.id);
  });

  testWidgets('the D-pad reaches both cards of a scoped picker', (tester) async {
    await tester.pumpWidget(app(AddConnectionScreen(targetProfile: profile('Den'))));
    await tester.pumpAndSettle();

    // The cards share a debugLabel, so track focus-node identity instead.
    final visited = <FocusNode>{};
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus;
      if (focused != null) visited.add(focused);
    }

    expect(visited.length, greaterThanOrEqualTo(2), reason: 'D-pad did not reach every card');
  });
}
