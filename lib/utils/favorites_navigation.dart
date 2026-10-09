import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/library_layout.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../providers/discover_provider.dart';
import '../screens/hub_detail_screen.dart';
import '../services/jellyfin_client.dart';

/// Open the PlezyFin account's Favourites: the user's favourite movies and
/// shows on that server, as a See All list (Adrian, 2026-10-09).
void openAccountFavorites(BuildContext context, JellyfinClient client) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => HubDetailScreen(
        hub: MediaHub(
          id: jellyfinFavoritesHubId,
          identifier: jellyfinFavoritesHubId,
          title: t.navigation.favorites,
          type: 'mixed',
          items: const [],
          more: true,
          serverId: client.serverId,
          serverName: client.serverName,
        ),
      ),
    ),
  );
}

/// Open an account entry's page from the menu: Favourites, or every item of
/// Continue Watching or Next Up (a folded one has no home row to see them in).
void openLayoutEntry(BuildContext context, LayoutEntry entry, {JellyfinClient? client}) {
  if (entry == LayoutEntry.favorites) {
    if (client != null) openAccountFavorites(context, client);
    return;
  }
  final discover = context.read<DiscoverProvider?>();
  if (discover == null) return;
  final nextUp = entry == LayoutEntry.nextUp;
  List<MediaItem> pick(List<MediaItem> items) {
    final split = DiscoverProvider.splitOnDeck(items);
    return nextUp ? split.nextUp : split.resume;
  }

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => HubDetailScreen(
        hub: MediaHub(
          id: nextUp ? 'nextup' : 'continue_watching',
          identifier: nextUp ? 'home.nextup' : '_continue_watching_',
          title: nextUp ? t.discover.nextUp : t.discover.continueWatching,
          type: 'mixed',
          items: pick(discover.onDeck),
        ),
        loadItems: () async => pick(await discover.loadAllContinueWatching()),
        isInContinueWatching: true,
        onRemoveFromContinueWatching: discover.refreshContinueWatching,
      ),
    ),
  );
}
