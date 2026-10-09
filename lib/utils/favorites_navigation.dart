import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../media/media_hub.dart';
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
