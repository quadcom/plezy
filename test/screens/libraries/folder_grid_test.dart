import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/libraries/folder_grid_tile.dart';
import 'package:plezy/screens/libraries/folder_tree_view.dart';

// local/plans/home-video-grid.md
void main() {
  group('middleEllipsis', () {
    const style = TextStyle(fontSize: 13);

    test('keeps a name that fits', () {
      expect(middleEllipsis('Short.mkv', style: style, maxWidth: 400, maxLines: 2), 'Short.mkv');
    });

    test('cuts the middle and keeps the end of a long name', () {
      const name = 'Noise test hqdn3d luma 4 chroma 3 temporal 6 strength4_crf20_preset_slow_final_v2.mkv';
      final fitted = middleEllipsis(name, style: style, maxWidth: 120, maxLines: 1);
      expect(fitted, contains('…'));
      expect(fitted.length, lessThan(name.length));
      expect(name.startsWith(fitted.split('…').first), isTrue);
      expect(name.endsWith(fitted.split('…').last), isTrue);
      expect(fitted.split('…').last, isNotEmpty);
    });
  });

  test('FolderGridSort.parse falls back to name', () {
    expect(FolderGridSort.parse('newest'), FolderGridSort.newest);
    expect(FolderGridSort.parse('largest'), FolderGridSort.largest);
    expect(FolderGridSort.parse(null), FolderGridSort.name);
    expect(FolderGridSort.parse('bogus'), FolderGridSort.name);
  });
}
