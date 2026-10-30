import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

final terminalAppearance = TerminalAppearance();

class SkinDefinition {
  final String name, palette;
  final bool dark;
  final int seed;
  final int top, bottom;
  const SkinDefinition({
    required this.name,
    required this.palette,
    required this.dark,
    required this.seed,
    required this.top,
    required this.bottom,
  });
}

const builtInSkins = <String, SkinDefinition>{
  'emerald': SkinDefinition(
    name: '翡翠林海',
    palette: 'dark',
    dark: true,
    seed: 0xff167768,
    top: 0xff071f1b,
    bottom: 0xff145c4f,
  ),
  'sunset': SkinDefinition(
    name: '落日沙丘',
    palette: 'onelight',
    dark: false,
    seed: 0xffb85c38,
    top: 0xffffe3c8,
    bottom: 0xffe8a87c,
  ),
  'aurora': SkinDefinition(
    name: '极光之夜',
    palette: 'nord',
    dark: true,
    seed: 0xff3fc1c9,
    top: 0xff061a2b,
    bottom: 0xff123b4a,
  ),
  'sakura': SkinDefinition(
    name: '樱花和风',
    palette: 'light',
    dark: false,
    seed: 0xffc25b7c,
    top: 0xfffff0f4,
    bottom: 0xfff3c6d4,
  ),
  'neon': SkinDefinition(
    name: '赛博霓虹',
    palette: 'dracula',
    dark: true,
    seed: 0xffb34dff,
    top: 0xff100724,
    bottom: 0xff35104d,
  ),
  'ink': SkinDefinition(
    name: '水墨青山',
    palette: 'light',
    dark: false,
    seed: 0xff2f5d55,
    top: 0xffedf2ef,
    bottom: 0xffc9d9d3,
  ),
  'starry': SkinDefinition(
    name: '午夜星河',
    palette: 'dark',
    dark: true,
    seed: 0xff5b7cfa,
    top: 0xff040817,
    bottom: 0xff18294a,
  ),
  'coast': SkinDefinition(
    name: '蔚蓝海岸',
    palette: 'light',
    dark: false,
    seed: 0xff1677a8,
    top: 0xffe8f8ff,
    bottom: 0xffb7ddec,
  ),
};

class TerminalAppearance extends ChangeNotifier {
  final Future<File> Function() _file;
  TerminalAppearance({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/terminal-appearance.json',
          ));

  static const names = {
    'dark': '深灰',
    'black': '纯黑',
    'light': '浅色',
    'dracula': 'Dracula',
    'nord': 'Nord',
    'solarized': 'Solarized Dark',
    'onelight': 'One Light',
    'custom': '自定义',
  };
  static const customColorLabels = {
    'background': '背景',
    'foreground': '前景',
    'cursor': '光标',
    'selection': '选区',
    'black': '黑',
    'red': '红',
    'green': '绿',
    'yellow': '黄',
    'blue': '蓝',
    'magenta': '洋红',
    'cyan': '青',
    'white': '白',
    'brightBlack': '亮黑',
    'brightRed': '亮红',
    'brightGreen': '亮绿',
    'brightYellow': '亮黄',
    'brightBlue': '亮蓝',
    'brightMagenta': '亮洋红',
    'brightCyan': '亮青',
    'brightWhite': '亮白',
  };
  String palette = 'dark';
  String uiTheme = 'system';
  String skin = 'none';
  String uiFont = '', terminalFont = '', cjkFont = '';
  int fontSize = 13;
  bool copyOnSelect = false;
  Map<String, int> customColors = const {};
  Future<void> _pending = Future.value();

  /// Seeds the editor from a built-in palette instead of starting blank.
  static Map<String, int> defaultCustomColors([String palette = 'dark']) {
    final theme = themeFor(palette == 'custom' ? 'dark' : palette);
    return {
      'background': theme.background.toARGB32(),
      'foreground': theme.foreground.toARGB32(),
      'cursor': theme.cursor.toARGB32(),
      'selection': theme.selection.toARGB32(),
      'black': theme.black.toARGB32(),
      'red': theme.red.toARGB32(),
      'green': theme.green.toARGB32(),
      'yellow': theme.yellow.toARGB32(),
      'blue': theme.blue.toARGB32(),
      'magenta': theme.magenta.toARGB32(),
      'cyan': theme.cyan.toARGB32(),
      'white': theme.white.toARGB32(),
      'brightBlack': theme.brightBlack.toARGB32(),
      'brightRed': theme.brightRed.toARGB32(),
      'brightGreen': theme.brightGreen.toARGB32(),
      'brightYellow': theme.brightYellow.toARGB32(),
      'brightBlue': theme.brightBlue.toARGB32(),
      'brightMagenta': theme.brightMagenta.toARGB32(),
      'brightCyan': theme.brightCyan.toARGB32(),
      'brightWhite': theme.brightWhite.toARGB32(),
    };
  }

  static TerminalTheme customTheme(Map<String, int> colors) {
    final d = TerminalThemes.defaultTheme;
    Color read(String key, Color fallback) {
      final value = colors[key];
      return value == null ? fallback : Color(value);
    }

    return TerminalTheme(
      cursor: read('cursor', d.cursor),
      selection: read('selection', d.selection),
      foreground: read('foreground', d.foreground),
      background: read('background', d.background),
      black: read('black', d.black),
      red: read('red', d.red),
      green: read('green', d.green),
      yellow: read('yellow', d.yellow),
      blue: read('blue', d.blue),
      magenta: read('magenta', d.magenta),
      cyan: read('cyan', d.cyan),
      white: read('white', d.white),
      brightBlack: read('brightBlack', d.brightBlack),
      brightRed: read('brightRed', d.brightRed),
      brightGreen: read('brightGreen', d.brightGreen),
      brightYellow: read('brightYellow', d.brightYellow),
      brightBlue: read('brightBlue', d.brightBlue),
      brightMagenta: read('brightMagenta', d.brightMagenta),
      brightCyan: read('brightCyan', d.brightCyan),
      brightWhite: read('brightWhite', d.brightWhite),
      searchHitBackground: d.searchHitBackground,
      searchHitBackgroundCurrent: d.searchHitBackgroundCurrent,
      searchHitForeground: d.searchHitForeground,
    );
  }

  TerminalTheme get activeTheme =>
      palette == 'custom' ? customTheme(customColors) : themeFor(palette);

  static TerminalTheme themeFor(String palette) {
    if (palette == 'black') return TerminalThemes.whiteOnBlack;
    if (palette == 'dracula') {
      return const TerminalTheme(
        cursor: Color(0xfff8f8f2),
        selection: Color(0x554bd5e0),
        foreground: Color(0xfff8f8f2),
        background: Color(0xff282a36),
        black: Color(0xff21222c),
        red: Color(0xffff5555),
        green: Color(0xff50fa7b),
        yellow: Color(0xfff1fa8c),
        blue: Color(0xffbd93f9),
        magenta: Color(0xffff79c6),
        cyan: Color(0xff8be9fd),
        white: Color(0xfff8f8f2),
        brightBlack: Color(0xff6272a4),
        brightRed: Color(0xffff6e6e),
        brightGreen: Color(0xff69ff94),
        brightYellow: Color(0xffffffa5),
        brightBlue: Color(0xffd6acff),
        brightMagenta: Color(0xffff92df),
        brightCyan: Color(0xffa4ffff),
        brightWhite: Color(0xffffffff),
        searchHitBackground: Color(0xffffdf80),
        searchHitBackgroundCurrent: Color(0xffa1e4be),
        searchHitForeground: Color(0xff202830),
      );
    }
    if (palette == 'nord') {
      return const TerminalTheme(
        cursor: Color(0xffd8dee9),
        selection: Color(0x5588c0d0),
        foreground: Color(0xffd8dee9),
        background: Color(0xff2e3440),
        black: Color(0xff3b4252),
        red: Color(0xffbf616a),
        green: Color(0xffa3be8c),
        yellow: Color(0xffebcb8b),
        blue: Color(0xff81a1c1),
        magenta: Color(0xffb48ead),
        cyan: Color(0xff88c0d0),
        white: Color(0xffe5e9f0),
        brightBlack: Color(0xff4c566a),
        brightRed: Color(0xffbf616a),
        brightGreen: Color(0xffa3be8c),
        brightYellow: Color(0xffebcb8b),
        brightBlue: Color(0xff81a1c1),
        brightMagenta: Color(0xffb48ead),
        brightCyan: Color(0xff8fbcbb),
        brightWhite: Color(0xffeceff4),
        searchHitBackground: Color(0xffffdf80),
        searchHitBackgroundCurrent: Color(0xffa1e4be),
        searchHitForeground: Color(0xff202830),
      );
    }
    if (palette == 'solarized') {
      return const TerminalTheme(
        cursor: Color(0xff93a1a1),
        selection: Color(0x55268bd2),
        foreground: Color(0xff93a1a1),
        background: Color(0xff002b36),
        black: Color(0xff073642),
        red: Color(0xffdc322f),
        green: Color(0xff859900),
        yellow: Color(0xffb58900),
        blue: Color(0xff268bd2),
        magenta: Color(0xffd33682),
        cyan: Color(0xff2aa198),
        white: Color(0xffeee8d5),
        brightBlack: Color(0xff586e75),
        brightRed: Color(0xffcb4b16),
        brightGreen: Color(0xff586e75),
        brightYellow: Color(0xff657b83),
        brightBlue: Color(0xff839496),
        brightMagenta: Color(0xff6c71c4),
        brightCyan: Color(0xff93a1a1),
        brightWhite: Color(0xfffdf6e3),
        searchHitBackground: Color(0xffffdf80),
        searchHitBackgroundCurrent: Color(0xffa1e4be),
        searchHitForeground: Color(0xff202830),
      );
    }
    if (palette == 'onelight') {
      return const TerminalTheme(
        cursor: Color(0xff526fff),
        selection: Color(0x5538384a),
        foreground: Color(0xff383a42),
        background: Color(0xfffafafa),
        black: Color(0xff383a42),
        red: Color(0xffe45649),
        green: Color(0xff50a14f),
        yellow: Color(0xffc18401),
        blue: Color(0xff0184bc),
        magenta: Color(0xffa626a4),
        cyan: Color(0xff0997b3),
        white: Color(0xffd3d3d3),
        brightBlack: Color(0xff696c77),
        brightRed: Color(0xffe45649),
        brightGreen: Color(0xff50a14f),
        brightYellow: Color(0xffc18401),
        brightBlue: Color(0xff0184bc),
        brightMagenta: Color(0xffa626a4),
        brightCyan: Color(0xff0997b3),
        brightWhite: Color(0xffffffff),
        searchHitBackground: Color(0xffffdf80),
        searchHitBackgroundCurrent: Color(0xffa1e4be),
        searchHitForeground: Color(0xff202830),
      );
    }
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
      final storedTheme = value['uiTheme'];
      final storedUiFont = value['uiFont'];
      final storedSkin = value['skin'];
      if (storedSkin is String &&
          (storedSkin == 'none' || builtInSkins.containsKey(storedSkin))) {
        skin = storedSkin;
      }
      final storedTerminalFont = value['terminalFont'];
      final storedCjkFont = value['cjkFont'];
      if (storedUiFont is String) uiFont = storedUiFont;
      if (storedTerminalFont is String) terminalFont = storedTerminalFont;
      if (storedCjkFont is String) cjkFont = storedCjkFont;
      final storedColors = value['customColors'];
      if (storedColors is Map) {
        final colors = <String, int>{};
        for (final entry in storedColors.entries) {
          final key = entry.key;
          final color = entry.value;
          if (key is String &&
              customColorLabels.containsKey(key) &&
              color is int &&
              color >= 0 &&
              color <= 0xffffffff) {
            colors[key] = color;
          }
        }
        if (colors.isNotEmpty) customColors = Map.unmodifiable(colors);
      }
      if (storedTheme is String &&
          {'system', 'dark', 'light'}.contains(storedTheme)) {
        uiTheme = storedTheme;
      }
      if (storedPalette is String && names.containsKey(storedPalette)) {
        palette = storedPalette;
      }
      if (storedSize is int && storedSize >= 10 && storedSize <= 28) {
        fontSize = storedSize;
      }
      copyOnSelect = value['copyOnSelect'] == true;
      notifyListeners();
    } on FileSystemException {
      // Appearance is optional; an unreadable preference never blocks startup.
    } on FormatException {
      // Keep usable defaults after interrupted or externally edited files.
    }
  }

  Future<void> save(
    String nextPalette,
    int nextSize, {
    String? nextUiTheme,
    String? nextUiFont,
    String? nextTerminalFont,
    String? nextCjkFont,
    String? nextSkin,
    Map<String, int>? nextCustomColors,
    bool? nextCopyOnSelect,
  }) {
    final nextMode = nextUiTheme ?? uiTheme;
    final nextColors = nextCustomColors ?? customColors;
    final validColors =
        nextColors.isEmpty ||
        nextColors.entries.every(
          (entry) =>
              customColorLabels.containsKey(entry.key) &&
              entry.value >= 0 &&
              entry.value <= 0xffffffff,
        );
    if (!names.containsKey(nextPalette) ||
        nextSize < 10 ||
        nextSize > 28 ||
        !{'system', 'dark', 'light'}.contains(nextMode) ||
        !validColors) {
      return Future.error(ArgumentError('无效的终端外观设置'));
    }
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'palette': nextPalette,
          'fontSize': nextSize,
          'uiTheme': nextMode,
          'uiFont': nextUiFont ?? uiFont,
          'terminalFont': nextTerminalFont ?? terminalFont,
          'cjkFont': nextCjkFont ?? cjkFont,
          'skin': nextSkin ?? skin,
          'customColors': nextColors,
          'copyOnSelect': nextCopyOnSelect ?? copyOnSelect,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
      palette = nextPalette;
      fontSize = nextSize;
      uiTheme = nextMode;
      uiFont = nextUiFont ?? uiFont;
      terminalFont = nextTerminalFont ?? terminalFont;
      cjkFont = nextCjkFont ?? cjkFont;
      skin = nextSkin ?? skin;
      customColors = Map.unmodifiable(nextColors);
      copyOnSelect = nextCopyOnSelect ?? copyOnSelect;
      notifyListeners();
    });
    _pending = operation;
    return operation;
  }
}
