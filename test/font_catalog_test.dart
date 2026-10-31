import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/font_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled and platform fonts are available in every picker list', () {
    expect(bundledFonts, contains('JetBrains Mono'));
    expect(bundledFonts, contains('Noto Sans SC'));
    expect(commonTerminalFonts, contains('JetBrains Mono'));
    expect(commonCjkFonts, contains('Noto Sans SC'));
    expect(platformDefaultUiFont(), isNotEmpty);
    expect(platformDefaultTerminalFont(), isNotEmpty);
    expect(monoFontFallback, contains('JetBrains Mono'));
    expect(monoFontFallback, contains('Cascadia Mono'));
    expect(monoFontFallback, contains('Menlo'));
  });

  test('font files referenced by pubspec exist', () {
    for (final path in const [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Bold.ttf',
      'assets/fonts/NotoSansSC-Regular.otf',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  test('font enumeration falls back to built-in families', () async {
    final families = await availableFontFamilies();
    expect(families, containsAll(bundledFonts));
    expect(families, contains(commonUiFonts.first));
    expect(families.toSet().length, families.length);
  });
}
