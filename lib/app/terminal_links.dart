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
