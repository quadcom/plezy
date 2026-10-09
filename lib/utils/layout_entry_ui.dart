import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/library_layout.dart';

/// The name an account entry shows under in menus and Manage Libraries.
String layoutEntryTitle(LayoutEntry entry) => switch (entry) {
  LayoutEntry.continueWatching => t.discover.continueWatching,
  LayoutEntry.nextUp => t.discover.nextUp,
  LayoutEntry.favorites => t.navigation.favorites,
};

/// The icon an account entry shows with.
IconData layoutEntryIcon(LayoutEntry entry) => switch (entry) {
  LayoutEntry.continueWatching => Symbols.play_circle_rounded,
  LayoutEntry.nextUp => Symbols.skip_next_rounded,
  LayoutEntry.favorites => Symbols.favorite_rounded,
};
