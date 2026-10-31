import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../database/app_database.dart';
import '../i18n/strings.g.dart';
import '../focus/focusable_button.dart';
import '../focus/key_event_utils.dart';
import '../media/media_backend.dart';
import '../media/media_browser_dialect.dart';
import '../navigation/profile_session_screen.dart';
import '../utils/navigation_transitions.dart';
import '../widgets/backend_badge.dart';
import 'settings/add_jellyfin_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    this.initialErrorMessage,
    this.initializeServices = true,
    this.databaseRecoveryRequired = false,
  });

  final String? initialErrorMessage;
  final bool initializeServices;
  final bool databaseRecoveryRequired;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  String? _errorMessage;
  Future<void>? _recoveryAcknowledgement;
  bool _recoveryAcknowledged = false;

  @override
  void initState() {
    super.initState();
    _errorMessage = widget.initialErrorMessage;
  }

  Future<bool> _prepareDatabaseRecoveryForSignIn() async {
    if (!widget.databaseRecoveryRequired || _recoveryAcknowledged) return true;
    final acknowledgement = _recoveryAcknowledgement ??= context
        .read<AppDatabase>()
        .acknowledgeTvosDatabaseRecoveryRequired();
    try {
      await acknowledgement;
      _recoveryAcknowledged = true;
      if (mounted) setState(() => _errorMessage = null);
      return mounted;
    } catch (_) {
      _recoveryAcknowledgement = null;
      if (mounted) setState(() => _errorMessage = t.auth.localDataRecoveryRequired);
      return false;
    }
  }

  /// PlezyFin is the only server Plezy signs in to (Adrian, 2026-10-31: "No
  /// plex, no Emby"). Plex and Emby sign-in live on the `plex-legacy` branch.
  Future<void> _connectToPlezyFin() async {
    if (!await _prepareDatabaseRecoveryForSignIn()) return;
    if (!mounted) return;
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AddJellyfinScreen(dialect: MediaBrowserDialect.jellyfin)),
    );
    if (!mounted || added != true) return;
    // The connection persisted and the manager registered the client; move
    // straight to the main screen. [MainScreen] reads the active client
    // from the server provider, so no client argument is needed here.
    unawaited(Navigator.pushReplacement(context, fadeRoute(const ProfileSessionScreen())));
  }

  @override
  Widget build(BuildContext context) {
    // Use two-column layout on desktop, single column on mobile
    final isDesktop = MediaQuery.sizeOf(context).width > 700;

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: Scaffold(
        body: Center(
          child: Container(
            constraints: BoxConstraints(maxWidth: isDesktop ? 800 : 400),
            padding: .fromLTRB(24, 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
            child: isDesktop
                ? Row(
                    crossAxisAlignment: .center,
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: .center,
                          crossAxisAlignment: .center,
                          children: [
                            Image.asset('assets/plezy.png', width: 120, height: 120),
                            const SizedBox(height: 24),
                            Text(
                              t.app.title,
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: .bold),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 48),
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: .min,
                              crossAxisAlignment: .stretch,
                              children: [_buildAuthBody()],
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: .min,
                      crossAxisAlignment: .stretch,
                      children: [
                        Image.asset('assets/plezy.png', width: 120, height: 120),
                        const SizedBox(height: 24),
                        Text(
                          t.app.title,
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: .bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 48),
                        _buildAuthBody(),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildAuthBody() {
    const dialect = MediaBrowserDialect.jellyfin;
    void connect() => unawaited(_connectToPlezyFin());
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        FocusableButton(
          autofocus: true,
          onPressed: connect,
          useBackgroundFocus: true,
          child: ElevatedButton.icon(
            onPressed: connect,
            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const BackendBadge(backend: MediaBackend.jellyfin, size: 18),
            label: Text(t.auth.connectToMediaBrowser(product: dialect.productName)),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
