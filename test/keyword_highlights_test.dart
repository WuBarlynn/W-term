import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/keyword_highlights.dart';

void main() {
  test('keyword matches are case-insensitive and non-overlapping', () {
    final matches = findKeywordMatches(
      ['ERROR at line', 'error and Error', 'all good'],
      ['error', 'line'],
    );
    expect(matches.length, 4);
    expect(matches.first.line, 0);
    expect(matches.first.start, 0);
    expect(matches.first.end, 5);
    expect(matches[1].line, 0);
    expect(matches[1].start, 9);
    expect(matches[2].line, 1);
    expect(matches[3].line, 1);
  });

  test('blank and oversized keywords are ignored', () {
    expect(findKeywordMatches(['text'], ['', '   ', 'x' * 65]), isEmpty);
  });

  test('keyword settings round-trip and bound the list', () async {
    final directory = await Directory.systemTemp.createTemp('wterm-keywords-');
    final file = File('${directory.path}/keywords.json');
    try {
      final settings = KeywordHighlightSettings(file: () async => file);
      await settings.save(
        nextEnabled: true,
        nextKeywords: [
          'ERROR',
          'ERROR',
          ' 失败 ',
          ...[for (var i = 0; i < 25; i++) 'k$i'],
        ],
        nextColorArgb: 0xFFFF6B6B,
      );
      expect(settings.keywords.length, 20);
      expect(settings.keywords, containsAll(['ERROR', '失败']));
      final restored = KeywordHighlightSettings(file: () async => file);
      await restored.load();
      expect(restored.enabled, isTrue);
      expect(restored.colorArgb, 0xFFFF6B6B);
      expect(restored.keywords.length, 20);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
