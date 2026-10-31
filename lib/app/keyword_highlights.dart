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

class KeywordHighlightRule {
  final List<String> tags;
  final String pattern;
  const KeywordHighlightRule(this.tags, this.pattern);

  Map<String, Object?> toJson() => {'tags': tags, 'pattern': pattern};

  static KeywordHighlightRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pattern = raw['pattern'];
    final tags = raw['tags'];
    if (pattern is! String ||
        pattern.trim().isEmpty ||
        pattern.length > 256 ||
        tags is! List) {
      return null;
    }
    final cleaned = tags
        .whereType<String>()
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty && tag.length <= 48)
        .toSet()
        .take(20)
        .toList();
    return KeywordHighlightRule(cleaned, pattern.trim());
  }
}

/// Finds non-overlapping regex matches for rules whose tags intersect [hostTags].
List<KeywordMatch> findRegexMatches(
  List<String> lines,
  List<KeywordHighlightRule> rules,
  Set<String> hostTags, {
  int maxMatches = 200,
}) {
  final applicable = rules.where(
    (rule) => rule.tags.isEmpty || rule.tags.any(hostTags.contains),
  );
  final patterns = <RegExp>[];
  for (final rule in applicable) {
    try {
      patterns.add(RegExp(rule.pattern, caseSensitive: false, multiLine: true));
    } catch (_) {
      // Invalid expressions are ignored until edited.
    }
  }
  if (patterns.isEmpty) return const [];
  final matches = <KeywordMatch>[];
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(lines[lineIndex])) {
        if (match.start == match.end) continue;
        matches.add(KeywordMatch(lineIndex, match.start, match.end));
        if (matches.length >= maxMatches) return matches;
      }
    }
  }
  return matches;
}

class KeywordHighlightSettings extends ChangeNotifier {
  final Future<File> Function() _file;
  bool enabled = false;
  List<String> keywords = const [];
  List<KeywordHighlightRule> hostRules = const [];
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
      final rawRules = value['hostRules'];
      if (rawRules is List) {
        hostRules = rawRules
            .map(KeywordHighlightRule.fromJson)
            .whereType<KeywordHighlightRule>()
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
    'hostRules': hostRules.map((rule) => rule.toJson()).toList(),
    'colorArgb': colorArgb,
  };

  Future<Map<String, Object?>> exportSynced() async {
    await _pending.catchError((Object _) {});
    return toJson();
  }

  Future<void> applySynced(Object? data) async {
    if (data is! Map) return;
    final rawKeywords = data['keywords'];
    final rawRules = data['hostRules'];
    final color = data['colorArgb'];
    await save(
      nextEnabled: data['enabled'] == true,
      nextKeywords: rawKeywords is List
          ? rawKeywords.whereType<String>().toList()
          : const [],
      nextHostRules: rawRules is List
          ? rawRules
                .map(KeywordHighlightRule.fromJson)
                .whereType<KeywordHighlightRule>()
                .toList()
          : const [],
      nextColorArgb: color is int && color >= 0 && color <= 0xffffffff
          ? color
          : colorArgb,
    );
  }

  Future<void> save({
    required bool nextEnabled,
    required List<String> nextKeywords,
    List<KeywordHighlightRule> nextHostRules = const [],
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
          'hostRules': nextHostRules
              .take(20)
              .map((rule) => rule.toJson())
              .toList(),
          'colorArgb': nextColorArgb,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
      enabled = nextEnabled;
      keywords = cleaned;
      hostRules = nextHostRules.take(20).toList();
      colorArgb = nextColorArgb;
      notifyListeners();
    });
    _pending = operation;
    return operation;
  }
}

final keywordHighlights = KeywordHighlightSettings();
