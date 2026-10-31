import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/terminal_links.dart';

void main() {
  test('link spans trim prose punctuation', () {
    final spans = findLinkSpans(
      'See https://example.com/docs, and http://a.test/x?q=1.',
    );
    expect(spans, hasLength(2));
    expect(spans[0].start, 4);
    expect(spans[0].end, 28);
    expect(spans[1].start, 34);
    expect(spans[1].end, 53);
  });

  test('unbalanced closing parenthesis is not part of the link', () {
    final spans = findLinkSpans('(https://example.com/a) done');
    expect(spans, hasLength(1));
    expect(spans.single.end, 22);
    expect(findLinkSpans('no links here'), isEmpty);
    expect(findLinkSpans('http://'), isEmpty);
    expect(findLinkSpans('https://a'), hasLength(1));
  });

  test('oversized lines are ignored to bound rendering cost', () {
    expect(findLinkSpans('https://a.test/${'x' * 9000}'), isEmpty);
  });
}
