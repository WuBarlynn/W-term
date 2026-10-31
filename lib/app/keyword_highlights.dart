import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class KeywordMatch {
  final int line, start, end;
  const KeywordMatch(this.line, this.start, this.end);
}

/// Case-insensitive, non-overlapping keyword matches for visible buffer text.
List<KeywordMatch> findKeywordMatches(
  List<String> lines,
  List<String> keywords, {
  int maxMatches = 200,
}) {
  final values = keywords
      .map((keyword) => keyword.trim().toLowerCase())
      .where((keyword) => keyword.isNotEmpty && keyword.length <= 64)
      .toSet()
      .toList();
  if (values.isEmpty) return const [];
  final matches = <KeywordMatch>[];
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex].toLowerCase();
    var offset = 0;
    while (offset < line.length && matches.length < maxMatches) {
      var best = -1;
      var bestLength = 0;
      for (final keyword in values) {
        final index = line.indexOf(keyword, offset);
        if (index < 0) continue;
        if (best < 0 ||
            index < best ||
            (index == best && keyword.length > bestLength)) {
          best = index;
          bestLength = keyword.length;
        }
      }
      if (best < 0) break;
      matches.add(KeywordMatch(lineIndex, best, best + bestLength));
      offset = best + bestLength;
    }
    if (matches.length >= maxMatches) break;
  }
  return matches;
}

class KeywordHighlightSettings extends ChangeNotifier {
  final Future<File> Function() _file;
  bool enabled = false;
  List<String> keywords = const [];
  int colorArgb = 0xFFFFD166;
  Future<void> _pending = Future.value();

  KeywordHighlightSettings({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/keyword-highlights.json',
          ));

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return;
      enabled = value['enabled'] == true;
      final raw = value['keywords'];
      if (raw is List) {
        keywords = raw
            .whereType<String>()
            .map((keyword) => keyword.trim())
            .where((keyword) => keyword.isNotEmpty && keyword.length <= 64)
            .toSet()
            .take(20)
            .toList();
      }
      final color = value['colorArgb'];
      if (color is int && color >= 0 && color <= 0xffffffff) {
        colorArgb = color;
      }
      notifyListeners();
    } catch (_) {
      // Highlighting is optional and must not block terminals.
    }
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'enabled': enabled,
    'keywords': keywords,
    'colorArgb': colorArgb,
  };

  Future<Map<String, Object?>> exportSynced() async {
    await _pending.catchError((Object _) {});
    return toJson();
  }

  Future<void> applySynced(Object? data) async {
    if (data is! Map) return;
    final rawKeywords = data['keywords'];
    final color = data['colorArgb'];
    await save(
      nextEnabled: data['enabled'] == true,
      nextKeywords: rawKeywords is List
          ? rawKeywords.whereType<String>().toList()
          : const [],
      nextColorArgb: color is int && color >= 0 && color <= 0xffffffff
          ? color
          : colorArgb,
    );
  }

  Future<void> save({
    required bool nextEnabled,
    required List<String> nextKeywords,
    required int nextColorArgb,
  }) {
    final cleaned = nextKeywords
        .map((keyword) => keyword.trim())
        .where((keyword) => keyword.isNotEmpty && keyword.length <= 64)
        .toSet()
        .take(20)
        .toList();
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'enabled': nextEnabled,
          'keywords': cleaned,
          'colorArgb': nextColorArgb,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
      enabled = nextEnabled;
      keywords = cleaned;
      colorArgb = nextColorArgb;
      notifyListeners();
    });
    _pending = operation;
    return operation;
  }
}

final keywordHighlights = KeywordHighlightSettings();
