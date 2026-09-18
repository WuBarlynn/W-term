import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

final terminalAppearance = TerminalAppearance();

class TerminalAppearance extends ChangeNotifier {
  final Future<File> Function() _file;
  TerminalAppearance({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/terminal-appearance.json',
          ));

  static const names = {'dark': '深灰', 'black': '纯黑', 'light': '浅色'};
  String palette = 'dark';
  int fontSize = 13;
  Future<void> _pending = Future.value();

  static TerminalTheme themeFor(String palette) {
    if (palette == 'black') return TerminalThemes.whiteOnBlack;
    if (palette != 'light') return TerminalThemes.defaultTheme;
    return const TerminalTheme(
      cursor: Color(0xff243447),
      selection: Color(0x553884c4),
      foreground: Color(0xff243447),
      background: Color(0xfffafbfc),
      black: Color(0xff202830),
      red: Color(0xffb42332),
      green: Color(0xff176b38),
      yellow: Color(0xff856000),
      blue: Color(0xff145eb0),
      magenta: Color(0xff8c329a),
      cyan: Color(0xff007078),
      white: Color(0xffd3d8df),
      brightBlack: Color(0xff52606d),
      brightRed: Color(0xffbc2030),
      brightGreen: Color(0xff00753a),
      brightYellow: Color(0xff8a6000),
      brightBlue: Color(0xff005db8),
      brightMagenta: Color(0xff923ca5),
      brightCyan: Color(0xff007078),
      brightWhite: Color(0xffe5e9ee),
      searchHitBackground: Color(0xffffdf80),
      searchHitBackgroundCurrent: Color(0xffa1e4be),
      searchHitForeground: Color(0xff202830),
    );
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return;
      final storedPalette = value['palette'];
      final storedSize = value['fontSize'];
      if (storedPalette is String && names.containsKey(storedPalette)) {
        palette = storedPalette;
      }
      if (storedSize is int && storedSize >= 10 && storedSize <= 28) {
        fontSize = storedSize;
      }
      notifyListeners();
    } on FileSystemException {
      // Appearance is optional; an unreadable preference never blocks startup.
    } on FormatException {
      // Keep usable defaults after interrupted or externally edited files.
    }
  }

  Future<void> save(String nextPalette, int nextSize) {
    if (!names.containsKey(nextPalette) || nextSize < 10 || nextSize > 28) {
      return Future.error(ArgumentError('无效的终端外观设置'));
    }
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'palette': nextPalette, 'fontSize': nextSize}),
        flush: true,
      );
      await temporary.rename(file.path);
      palette = nextPalette;
      fontSize = nextSize;
      notifyListeners();
    });
    _pending = operation;
    return operation;
  }
}
