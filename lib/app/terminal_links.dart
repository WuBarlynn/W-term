class LinkSpan {
  final int start, end;
  const LinkSpan(this.start, this.end);
}

final _urlPattern = RegExp(
  r'https?://[^\s<>"'
  ']+',
  caseSensitive: false,
);

/// Finds clickable http(s) URLs in one terminal line, trimming punctuation
/// that is usually prose rather than part of the link.
List<LinkSpan> findLinkSpans(String line) {
  if (line.isEmpty || line.length > 8192) return const [];
  final spans = <LinkSpan>[];
  for (final match in _urlPattern.allMatches(line)) {
    var end = match.end;
    while (end > match.start) {
      final last = line[end - 1];
      if ('.,;:!?'.contains(last)) {
        end--;
        continue;
      }
      if (last == ')' &&
          ')'.allMatches(line.substring(match.start, end)).length >
              '('.allMatches(line.substring(match.start, end)).length) {
        end--;
        continue;
      }
      break;
    }
    if (end - match.start > 8) {
      spans.add(LinkSpan(match.start, end));
    }
  }
  return spans;
}

final _pathPattern = RegExp(
  r"""(?:/|\.{1,2}/)[^\s"'<>|]+|\.?[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_.-]+)+|(?:\.?[A-Za-z0-9_][A-Za-z0-9_.-]*\.[A-Za-z][A-Za-z0-9]{0,7})""",
);

String? _trimPath(String value) {
  var start = 0, end = value.length;
  const leading = '"\'([{<';
  const trailing = '.,;:!?)]}>\'"';
  while (start < end && leading.contains(value[start])) {
    start++;
  }
  while (end > start) {
    final last = value[end - 1];
    if (trailing.contains(last)) {
      end--;
      continue;
    }
    break;
  }
  if (end - start < 2) return null;
  var result = value.substring(start, end);
  // file.py:12 / file.py:12:4 line references point at the file itself.
  result = result.replaceFirst(RegExp(r':\d+(?::\d+)?$'), '');
  if (result.isEmpty) return null;
  return result;
}

/// Finds a path-like token under [column] in a terminal line. URLs are not
/// returned; callers handle links separately. Paths containing spaces must be
/// selected explicitly instead.
String? findPathAt(String line, int column, {int maxLength = 4096}) {
  if (line.isEmpty || line.length > 8192) return null;
  RegExpMatch? best;
  for (final match in _pathPattern.allMatches(line)) {
    if (column < match.start || column >= match.end) continue;
    if (best == null ||
        match.start < best.start ||
        (match.start == best.start && match.end > best.end)) {
      best = match;
    }
  }
  if (best == null) return null;
  final path = _trimPath(best.group(0)!);
  if (path == null || path.length > maxLength) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) return null;
  if (!path.contains('/') &&
      RegExp(
        r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$',
      ).hasMatch(path) &&
      const {
        'com',
        'net',
        'org',
        'io',
        'co',
        'cn',
        'dev',
        'app',
        'ai',
        'edu',
        'gov',
      }.contains(path.split('.').last.toLowerCase())) {
    return null;
  }
  return path;
}

