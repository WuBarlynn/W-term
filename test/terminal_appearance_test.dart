import 'dart:io';

import 'package:flutter/material.dart';
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

  test('custom terminal colors and copy-on-select round-trip', () async {
    final settings = TerminalAppearance(file: () async => file);
    final colors = TerminalAppearance.defaultCustomColors('nord');
    colors['background'] = 0xff102030;
    colors['selection'] = 0x44112233;
    await settings.save(
      'custom',
      15,
      nextCustomColors: colors,
      nextCopyOnSelect: true,
      nextCursorStyle: 'verticalBar',
      nextBottomPadding: 24,
      nextScrollback: 20000,
      nextUiToneFollowsTerminal: true,
    );
    expect(settings.activeTheme.background, const Color(0xff102030));
    expect(settings.activeTheme.selection, const Color(0x44112233));

    final restored = TerminalAppearance(file: () async => file);
    await restored.load();
    expect(restored.palette, 'custom');
    expect(restored.copyOnSelect, isTrue);
    expect(restored.cursorStyle, 'verticalBar');
    expect(restored.bottomPadding, 24);
    expect(restored.scrollback, 20000);
    expect(restored.uiToneFollowsTerminal, isTrue);
    expect(restored.customColors['background'], 0xff102030);
    expect(restored.activeTheme.background, const Color(0xff102030));

    await expectLater(
      settings.save('custom', 15, nextCustomColors: const {'background': -1}),
      throwsArgumentError,
    );
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
