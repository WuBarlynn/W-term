import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/imported_fonts.dart';

Uint8List fontBytes([int tail = 0]) => Uint8List.fromList([
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  tail,
]);

void main() {
  test('imports, reloads and removes a font from app storage', () async {
    final directory = await Directory.systemTemp.createTemp('wterm-fonts-');
    final registered = <String, int>{};
    Future<void> register(String name, Uint8List bytes) async {
      expect(isSupportedFontBytes(bytes), isTrue);
      registered[name] = bytes.length;
    }

    try {
      final store = ImportedFonts(
        directory: () async => directory,
        register: register,
      );
      await store.load();
      final source = File('${directory.path}/source.ttf');
      await source.writeAsBytes(fontBytes());
      final imported = await store.importFile(source, 'Demo Mono');
      expect(imported.name, 'Demo Mono');
      expect(store.names, ['Demo Mono']);
      expect(registered['Demo Mono'], 12);
      expect(File('${directory.path}/${imported.file}').existsSync(), isTrue);

      final restored = ImportedFonts(
        directory: () async => directory,
        register: register,
      );
      await restored.load();
      expect(restored.names, ['Demo Mono']);
      expect(registered.containsKey('Demo Mono'), isTrue);

      await restored.remove(restored.entries.single);
      expect(restored.names, isEmpty);
      expect(File('${directory.path}/${imported.file}').existsSync(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('rejects invalid bytes, names and URL schemes', () async {
    final directory = await Directory.systemTemp.createTemp('wterm-fonts-bad-');
    try {
      final store = ImportedFonts(
        directory: () async => directory,
        register: (_, _) async {},
      );
      final source = File('${directory.path}/bad.ttf');
      await source.writeAsBytes(Uint8List.fromList(List.filled(12, 1)));
      await expectLater(
        store.importFile(source, 'Bad Font'),
        throwsA(isA<StateError>()),
      );
      final good = File('${directory.path}/good.ttf');
      await good.writeAsBytes(fontBytes());
      await expectLater(
        store.importFile(good, '   '),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        store.importUrl(Uri.parse('ftp://example.com/font.ttf'), 'FTP Font'),
        throwsA(isA<ArgumentError>()),
      );
      expect(validateImportedFontName('ok'), isNull);
      expect(validateImportedFontName(''), isNotNull);
      expect(validateImportedFontName('a' * 65), isNotNull);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
