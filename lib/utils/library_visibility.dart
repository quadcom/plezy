import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../media/media_backend.dart';
import '../media/media_library.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../services/jellyfin_client.dart';
import 'provider_extensions.dart';

/// Hide or show [library] where its backend keeps that choice.
///
/// A user preference lives on the server when the server has a place for it
/// (Adrian, 2026-10-09). Jellyfin and Emby keep hidden libraries in the user's
/// `MyMediaExcludes`, so the web client and every device agree. Plex has no
/// such list, so a Plex library is hidden on this device only.
Future<void> setLibraryHidden(
  BuildContext context,
  MediaLibrary library,
  bool hidden, {
  void Function()? checkCurrent,
}) async {
  final hiddenLibraries = context.read<HiddenLibrariesProvider>();
  if (library.backend == MediaBackend.plex) {
    await hiddenLibraries.setLibraryHidden(library.globalKey, hidden, checkCurrent: checkCurrent);
    return;
  }
  final libraries = context.read<LibrariesProvider>();
  final client = context.getMediaClientForLibrary(library);
  if (client is! JellyfinClient) {
    throw StateError('No Jellyfin or Emby client for ${library.globalKey}');
  }
  await client.setLibraryHiddenOnServer(library.id, hidden: hidden);
  checkCurrent?.call();
  libraries.markServerHidden(library.globalKey, hidden);
  // A library hidden on this device before the server could hold it would
  // otherwise stay folded after it is shown again.
  if (!hidden && hiddenLibraries.deviceHiddenLibraryKeys.contains(library.globalKey)) {
    await hiddenLibraries.unhideLibrary(library.globalKey, checkCurrent: checkCurrent);
  }
}
