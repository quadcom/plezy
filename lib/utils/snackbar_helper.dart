import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../navigation/profile_navigation_scope.dart';
import '../widgets/app_icon.dart';
import 'layout_constants.dart';
import 'platform_detector.dart';

/// Global key for the root ScaffoldMessenger, allowing snackbars to survive navigation.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Types of snackbars available in the app
enum SnackBarType { info, success, error }

const double _kDesktopSnackBarMaxWidth = 480.0;
const double _kDesktopSnackBarHorizontalInset = 16.0;
const EdgeInsets _kDismissibleSnackBarPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 14);

/// Utility functions for showing snackbars throughout the application

SnackBar _buildSnackBar(
  BuildContext context,
  ScaffoldMessengerState messenger, {
  required Widget content,
  required Color? backgroundColor,
  required Duration duration,
  bool? dismissible,
}) {
  final isDesktop = PlatformDetector.isDesktopOS();
  final tapToDismiss = dismissible ?? isDesktop;
  final body = tapToDismiss
      ? MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
            child: Padding(padding: _kDismissibleSnackBarPadding, child: content),
          ),
        )
      : content;

  return SnackBar(
    content: body,
    backgroundColor: backgroundColor,
    duration: duration,
    behavior: isDesktop ? SnackBarBehavior.floating : null,
    width: isDesktop ? _desktopSnackBarWidth(context) : null,
    padding: tapToDismiss ? EdgeInsets.zero : null,
  );
}

double _desktopSnackBarWidth(BuildContext context) {
  final windowWidth = MediaQuery.maybeSizeOf(context)?.width;
  if (windowWidth == null) return _kDesktopSnackBarMaxWidth;

  final insetPadding = SnackBarTheme.of(context).insetPadding;
  final horizontalInset = insetPadding == null
      ? _kDesktopSnackBarHorizontalInset * 2
      : insetPadding.left + insetPadding.right;
  final availableWidth = windowWidth - horizontalInset;
  final width = availableWidth > 0 ? availableWidth : windowWidth;
  return width < _kDesktopSnackBarMaxWidth ? width : _kDesktopSnackBarMaxWidth;
}

/// Every bar keeps the app's own dark background and readable text colour;
/// success and error are told apart by a small coloured icon instead of a
/// green or red fill, whose light text was hard to read
/// (local/plans/subtitle-download-fixes.md, part 1).
Duration _snackBarDuration(SnackBarType type) => switch (type) {
  SnackBarType.info || SnackBarType.success => AppDurations.snackBarDefault,
  SnackBarType.error => AppDurations.snackBarLong,
};

const _successIconColor = Color(0xFF4CAF50);
const _errorIconColor = Color(0xFFEF5350);

Widget _snackBarContent(String message, SnackBarType type) {
  final (icon, color) = switch (type) {
    SnackBarType.info => (null, null),
    SnackBarType.success => (Symbols.check_circle_rounded, _successIconColor),
    SnackBarType.error => (Symbols.error_rounded, _errorIconColor),
  };
  if (icon == null) return Text(message);
  return Row(
    children: [
      AppIcon(icon, fill: 1, size: 20, color: color),
      const SizedBox(width: 12),
      Flexible(child: Text(message)),
    ],
  );
}

void showSnackBar(
  BuildContext context,
  String message, {
  SnackBarType type = SnackBarType.info,
  Duration? duration,
  bool? dismissible,
}) {
  if (!context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    _buildSnackBar(
      context,
      messenger,
      content: _snackBarContent(message, type),
      backgroundColor: null,
      duration: duration ?? _snackBarDuration(type),
      dismissible: dismissible,
    ),
  );
}

void showAppSnackBar(BuildContext context, String message, {Duration? duration}) {
  showSnackBar(context, message, type: SnackBarType.info, duration: duration);
}

void showErrorSnackBar(BuildContext context, String message) {
  showSnackBar(context, message, type: SnackBarType.error);
}

/// Shows an error snackbar using the root ScaffoldMessenger (survives navigation).
void showGlobalErrorSnackBar(String message) {
  final messenger = rootScaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger.showSnackBar(
    _buildSnackBar(
      messenger.context,
      messenger,
      content: _snackBarContent(message, SnackBarType.error),
      backgroundColor: null,
      duration: AppDurations.snackBarLong,
    ),
  );
}

/// Shows an info snackbar through the main-screen messenger when available
/// (so it floats above the mobile NavigationBar), falling back to the root
/// messenger when the main screen is not mounted.
void showMainSnackBar(String message, {Duration duration = AppDurations.snackBarDefault}) {
  final messenger = profileNavigationRegistry.mainScaffoldMessenger ?? rootScaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(
      _buildSnackBar(messenger.context, messenger, content: Text(message), backgroundColor: null, duration: duration),
    );
}

void showSuccessSnackBar(BuildContext context, String message) {
  showSnackBar(context, message, type: SnackBarType.success);
}
