import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/files_pane.dart';

void main() {
  test('markdown preview detection is case-insensitive and conservative', () {
    expect(isMarkdownPreviewName('README.md'), isTrue);
    expect(isMarkdownPreviewName('docs/guide.MARKDOWN'), isTrue);
    expect(isMarkdownPreviewName('notes.mdown'), isTrue);
    expect(isMarkdownPreviewName('config.yaml'), isFalse);
    expect(isMarkdownPreviewName('readme.md.txt'), isFalse);
  });
}
