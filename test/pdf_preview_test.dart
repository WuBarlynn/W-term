import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/files_pane.dart';

void main() {
  test('PDF preview detection is case-insensitive', () {
    expect(isPdfPreviewName('manual.pdf'), isTrue);
    expect(isPdfPreviewName('MANUAL.PDF'), isTrue);
    expect(isPdfPreviewName('manual.pdf.txt'), isFalse);
    expect(isPdfPreviewName('readme.md'), isFalse);
    expect(maxInlinePdfBytes, 100 * 1024 * 1024);
  });
}
