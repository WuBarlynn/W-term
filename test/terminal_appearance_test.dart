import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/terminal_appearance.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wterm-appearance-test-');
    file = File('${directory.path}/settings.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'appearance survives restart and serializes overlapping updates',
    () async {
      final settings = TerminalAppearance(file: () async => file);
      var notifications = 0;
      settings.addListener(() => notifications++);
      await Future.wait([
        settings.save('light', 18),
        settings.save('black', 20),
      ]);
      final restored = TerminalAppearance(file: () async => file);
      await restored.load();
      expect(restored.palette, 'black');
      expect(restored.fontSize, 20);
      expect(notifications, 2);
      settings.dispose();
      restored.dispose();
    },
  );

  test('UI theme mode round-trips', () async {
    final settings = TerminalAppearance(file: () async => file);
    await settings.save(
      'dracula',
      16,
      nextUiTheme: 'dark',
      nextUiFont: 'UI Font',
      nextTerminalFont: 'Term Font',
      nextCjkFont: 'CJK Font',
      nextSkin: 'emerald',
    );
    final restored = TerminalAppearance(file: () async => file);
    await restored.load();
    expect(restored.palette, 'dracula');
    expect(restored.uiTheme, 'dark');
    expect(restored.uiFont, 'UI Font');
    expect(restored.terminalFont, 'Term Font');
    expect(restored.cjkFont, 'CJK Font');
    expect(restored.skin, 'emerald');
    expect(restored.fontSize, 16);
    settings.dispose();
    restored.dispose();
  });

  test('damaged or out of range preferences fall back to defaults', () async {
    for (final content in [
      '{broken',
      '{"palette":"missing","fontSize":1000}',
    ]) {
      await file.writeAsString(content);
      final settings = TerminalAppearance(file: () async => file);
      await settings.load();
      expect(settings.palette, 'dark');
      expect(settings.fontSize, 13);
      settings.dispose();
    }
  });

  test('failed writes do not change active settings and allow retry', () async {
    await Directory(file.path).create();
    final settings = TerminalAppearance(file: () async => file);
    await expectLater(
      settings.save('light', 18),
      throwsA(isA<FileSystemException>()),
    );
    expect(settings.palette, 'dark');
    await Directory(file.path).delete();
    await settings.save('light', 18);
    expect(settings.fontSize, 18);
    settings.dispose();
  });
}
