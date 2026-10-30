import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/server_conversion.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/video_controls/sheets/version_quality_sheet.dart';

/// The picker must say what is arriving: a play the server converted on its
/// own (outside-the-house cap) may not read as "Original" with the file's bitrate.
void main() {
  Widget harness({ServerConversion? conversion}) => MaterialApp(
    theme: monoTheme(dark: false),
    home: Scaffold(
      body: VersionQualityPicker(
        availableVersions: const [],
        selectedMediaIndex: 0,
        selectedQualityPreset: TranscodeQualityPreset.original,
        serverSupportsTranscoding: true,
        serverConversion: conversion,
        onVersionSelected: (_) {},
        onQualitySelected: (_) {},
      ),
    ),
  );

  testWidgets('a forced conversion shows what the server sends', (tester) async {
    await tester.pumpWidget(
      harness(
        conversion: const ServerConversion(
          bitrateKbps: 7104,
          maxWidth: 1920,
          maxHeight: 1080,
          reasonCodes: ['ContainerBitrateExceedsLimit'],
          forced: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Converted by server: 1080p, 7.1 Mbps — outside the house limit'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
  });

  testWidgets('a direct play shows no conversion line', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.textContaining('Converted by server'), findsNothing);
    expect(find.text('Original'), findsOneWidget);
  });
}
