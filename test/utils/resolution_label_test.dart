import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/resolution_label.dart';

void main() {
  group('resolutionLabelFromDimensions', () {
    test('full-frame sizes map to their nominal band', () {
      expect(resolutionLabelFromDimensions(3840, 2160), '4k');
      expect(resolutionLabelFromDimensions(1920, 1080), '1080');
      expect(resolutionLabelFromDimensions(1280, 720), '720');
      expect(resolutionLabelFromDimensions(720, 480), '480');
    });

    test('scope crops keep their band by width', () {
      expect(resolutionLabelFromDimensions(1920, 800), '1080');
      expect(resolutionLabelFromDimensions(3840, 1608), '4k');
      expect(resolutionLabelFromDimensions(1280, 536), '720');
    });

    test('a few pixels cropped off the width still counts', () {
      // From Hell (2001) on PlezyFin: a 1080p WEB-DL cropped to 1916x812.
      expect(resolutionLabelFromDimensions(1916, 812), '1080');
      expect(resolutionLabelFromDimensions(3836, 1600), '4k');
      expect(resolutionLabelFromDimensions(1916, 1036), '1080');
    });

    test('pillarboxed frames keep their band by height', () {
      expect(resolutionLabelFromDimensions(1440, 1080), '1080');
      expect(resolutionLabelFromDimensions(2880, 2160), '4k');
    });

    test('null dimensions give null', () {
      expect(resolutionLabelFromDimensions(null, null), isNull);
    });
  });
}
