import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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


class CustomSkin {
  static const maxBackgroundBytes = 2 * 1024 * 1024;
  final String id, name, palette;
  final bool dark;
  final int seed, base;
  final double overlay;
  final Uint8List? background;

  const CustomSkin({
    required this.id,
    required this.name,
    required this.palette,
    required this.dark,
    required this.seed,
    required this.base,
    required this.overlay,
    this.background,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'palette': palette,
    'dark': dark,
    'seed': seed,
    'base': base,
    'overlay': overlay,
    if (background != null) 'background': base64Encode(background!),
  };

  static CustomSkin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final palette = raw['palette'];
    final dark = raw['dark'];
    final seed = raw['seed'];
    final base = raw['base'];
    final overlay = raw['overlay'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 64 ||
        !{ 'auto', ...TerminalAppearance.names.keys }.contains(palette) ||
        dark is! bool ||
        seed is! int ||
        base is! int ||
        seed < 0 ||
        seed > 0xffffffff ||
        base < 0 ||
        base > 0xffffffff ||
        overlay is! num ||
        overlay < 0 ||
        overlay > 0.6) {
      return null;
    }
    Uint8List? background;
    final encoded = raw['background'];
    if (encoded != null) {
      if (encoded is! String || encoded.length > maxBackgroundBytes * 2) {
        return null;
      }
      try {
        background = base64Decode(encoded);
      } catch (_) {
        return null;
      }
      if (background.length > maxBackgroundBytes) return null;
    }
    return CustomSkin(
      id: id,
      name: name.trim(),
      palette: palette as String,
      dark: dark,
      seed: seed,
      base: base,
      overlay: overlay.toDouble(),
      background: background,
    );
  }
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
  static const fontWeights = {
    'normal': FontWeight.w400,
    'medium': FontWeight.w500,
    'semibold': FontWeight.w600,
    'bold': FontWeight.w700,
  };
  static const fontWeightNames = {
    'normal': '常规',
    'medium': '中等',
    'semibold': '半粗',
    'bold': '粗体',
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
  List<CustomSkin> customSkins = const [];
  String uiFont = '', terminalFont = '', cjkFont = '';
  int fontSize = 13;
  double lineHeight = 1.2;
  String fontWeight = 'normal';
  bool copyOnSelect = false;
  String cursorStyle = 'block';
  bool cursorBlink = false;
  int bottomPadding = 0;
  int scrollback = 5000;
  bool uiToneFollowsTerminal = false;
  Map<String, int> customColors = const {};
  FontWeight get terminalFontWeight =>
      fontWeights[fontWeight] ?? FontWeight.w400;
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

  CustomSkin? get activeCustomSkin {
    if (!skin.startsWith('custom:')) return null;
    final id = skin.substring(7);
    for (final item in customSkins) {
      if (item.id == id) return item;
    }
    return null;
  }

  SkinDefinition? get activeBuiltInSkin => builtInSkins[skin];
  bool get hasSkin => activeBuiltInSkin != null || activeCustomSkin != null;
  bool get activeSkinDark =>
      activeCustomSkin?.dark ?? activeBuiltInSkin?.dark ?? false;
  int get activeSkinSeed =>
      activeCustomSkin?.seed ?? activeBuiltInSkin?.seed ?? 0xff167768;
  int get activeSkinTop =>
      activeCustomSkin?.base ?? activeBuiltInSkin?.top ?? 0xff101820;
  int get activeSkinBottom =>
      activeCustomSkin?.base ?? activeBuiltInSkin?.bottom ?? 0xff101820;
  double get activeSkinOverlay => activeCustomSkin?.overlay ?? 0.18;
  Uint8List? get activeSkinBackground => activeCustomSkin?.background;
  String get activeSkinName =>
      activeCustomSkin?.name ?? activeBuiltInSkin?.name ?? '无皮肤';

  TerminalTheme get activeTheme {
    final custom = activeCustomSkin;
    TerminalTheme base;
    if (custom != null) {
      if (custom.palette == 'auto') {
        base = _autoGlassTheme(custom);
      } else if (custom.palette == 'custom') {
        base = customTheme(customColors);
      } else {
        base = themeFor(custom.palette);
      }
    } else if (activeBuiltInSkin != null) {
      base = themeFor(activeBuiltInSkin!.palette);
    } else {
      base = palette == 'custom' ? customTheme(customColors) : themeFor(palette);
    }
    if (!hasSkin) return base;
    return _copyTerminalTheme(
      base,
      background: base.background.withValues(alpha: 0.78),
    );
  }

  TerminalTheme _autoGlassTheme(CustomSkin custom) {
    final base = themeFor(custom.dark ? 'dark' : 'light');
    return _copyTerminalTheme(
      base,
      background: Color(custom.base).withValues(alpha: 0.78),
    );
  }

  TerminalTheme _copyTerminalTheme(
    TerminalTheme source, {
    Color? foreground,
    Color? background,
  }) => TerminalTheme(
    cursor: source.cursor,
    selection: source.selection,
    foreground: foreground ?? source.foreground,
    background: background ?? source.background,
    black: source.black,
    red: source.red,
    green: source.green,
    yellow: source.yellow,
    blue: source.blue,
    magenta: source.magenta,
    cyan: source.cyan,
    white: source.white,
    brightBlack: source.brightBlack,
    brightRed: source.brightRed,
    brightGreen: source.brightGreen,
    brightYellow: source.brightYellow,
    brightBlue: source.brightBlue,
    brightMagenta: source.brightMagenta,
    brightCyan: source.brightCyan,
    brightWhite: source.brightWhite,
    searchHitBackground: source.searchHitBackground,
    searchHitBackgroundCurrent: source.searchHitBackgroundCurrent,
    searchHitForeground: source.searchHitForeground,
  );

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
      final storedCustomSkins = value['customSkins'];
      if (storedCustomSkins is List) {
        final parsed = <CustomSkin>[];
        final ids = <String>{};
        for (final raw in storedCustomSkins.take(8)) {
          final item = CustomSkin.fromJson(raw);
          if (item != null && ids.add(item.id)) parsed.add(item);
        }
        customSkins = List.unmodifiable(parsed);
      }
      final storedSkin = value['skin'];
      if (storedSkin is String &&
          (storedSkin == 'none' ||
              builtInSkins.containsKey(storedSkin) ||
              (storedSkin.startsWith('custom:') &&
                  customSkins.any(
                    (item) => item.id == storedSkin.substring(7),
                  )))) {
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
      cursorBlink = value['cursorBlink'] == true;
      uiToneFollowsTerminal = value['uiToneFollowsTerminal'] == true;
      final storedCursor = value['cursorStyle'];
      if (storedCursor is String &&
          {'block', 'underline', 'verticalBar'}.contains(storedCursor)) {
        cursorStyle = storedCursor;
      }
      final storedLineHeight = value['lineHeight'];
      if (storedLineHeight is num && storedLineHeight >= 0.9 &&
          storedLineHeight <= 2) {
        lineHeight = storedLineHeight.toDouble();
      }
      final storedWeight = value['fontWeight'];
      if (storedWeight is String && fontWeights.containsKey(storedWeight)) {
        fontWeight = storedWeight;
      }
      final storedPadding = value['bottomPadding'];
      if (storedPadding is int && storedPadding >= 0 && storedPadding <= 64) {
        bottomPadding = storedPadding;
      }
      final storedScrollback = value['scrollback'];
      if (storedScrollback is int &&
          storedScrollback >= 1000 &&
          storedScrollback <= 100000) {
        scrollback = storedScrollback;
      }
      notifyListeners();
    } on FileSystemException {
      // Appearance is optional; an unreadable preference never blocks startup.
    } on FormatException {
      // Keep usable defaults after interrupted or externally edited files.
    }
  }

  Map<String, Object?> toJson() => {
    'palette': palette,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'fontWeight': fontWeight,
    'uiTheme': uiTheme,
    'uiFont': uiFont,
    'terminalFont': terminalFont,
    'cjkFont': cjkFont,
    'skin': skin,
    'customSkins': customSkins.map((item) => item.toJson()).toList(),
    'customColors': customColors,
    'copyOnSelect': copyOnSelect,
    'cursorStyle': cursorStyle,
    'cursorBlink': cursorBlink,
    'bottomPadding': bottomPadding,
    'scrollback': scrollback,
    'uiToneFollowsTerminal': uiToneFollowsTerminal,
  };

  Future<Map<String, Object?>> exportSynced() async {
    await _pending.catchError((Object _) {});
    return toJson();
  }

  Future<void> applySynced(Object? data) async {
    if (data is! Map) return;
    final nextPalette = data['palette'];
    final nextSize = data['fontSize'];
    if (nextPalette is! String ||
        !names.containsKey(nextPalette) ||
        nextSize is! int ||
        nextSize < 10 ||
        nextSize > 28) {
      return;
    }
    final nextTheme = data['uiTheme'];
    final rawCustomSkins = data['customSkins'];
    final parsedCustomSkins = <CustomSkin>[];
    if (rawCustomSkins is List) {
      final ids = <String>{};
      for (final raw in rawCustomSkins.take(8)) {
        final item = CustomSkin.fromJson(raw);
        if (item != null && ids.add(item.id)) parsedCustomSkins.add(item);
      }
    }
    final nextSkin = data['skin'];
    final nextSkinValue = nextSkin is String &&
            (nextSkin == 'none' ||
                builtInSkins.containsKey(nextSkin) ||
                (nextSkin.startsWith('custom:') &&
                    parsedCustomSkins.any(
                      (item) => item.id == nextSkin.substring(7),
                    )))
        ? nextSkin
        : skin;
    final rawColors = data['customColors'];
    final colors = <String, int>{};
    if (rawColors is Map) {
      for (final entry in rawColors.entries) {
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
    }
    await save(
      nextPalette,
      nextSize,
      nextUiTheme: nextTheme is String && {'system', 'dark', 'light'}.contains(nextTheme)
          ? nextTheme
          : uiTheme,
      nextUiFont: data['uiFont'] is String ? data['uiFont'] as String : uiFont,
      nextTerminalFont: data['terminalFont'] is String
          ? data['terminalFont'] as String
          : terminalFont,
      nextCjkFont: data['cjkFont'] is String ? data['cjkFont'] as String : cjkFont,
      nextSkin: nextSkinValue,
      nextCustomSkins: rawCustomSkins is List
          ? parsedCustomSkins
          : customSkins,
      nextCustomColors: rawColors is Map ? colors : customColors,
      nextCopyOnSelect: data['copyOnSelect'] == true,
      nextCursorStyle: data['cursorStyle'] is String
          ? data['cursorStyle'] as String
          : cursorStyle,
      nextCursorBlink: data['cursorBlink'] == true,
      nextLineHeight: data['lineHeight'] is num
          ? (data['lineHeight'] as num).toDouble()
          : lineHeight,
      nextFontWeight: data['fontWeight'] is String &&
              fontWeights.containsKey(data['fontWeight'])
          ? data['fontWeight'] as String
          : fontWeight,
      nextBottomPadding: data['bottomPadding'] is int
          ? data['bottomPadding'] as int
          : bottomPadding,
      nextScrollback: data['scrollback'] is int
          ? data['scrollback'] as int
          : scrollback,
      nextUiToneFollowsTerminal: data['uiToneFollowsTerminal'] == true,
    );
  }

  Future<void> save(
    String nextPalette,
    int nextSize, {
    String? nextUiTheme,
    String? nextUiFont,
    String? nextTerminalFont,
    String? nextCjkFont,
    String? nextSkin,
    List<CustomSkin>? nextCustomSkins,
    Map<String, int>? nextCustomColors,
    bool? nextCopyOnSelect,
    String? nextCursorStyle,
    bool? nextCursorBlink,
    double? nextLineHeight,
    String? nextFontWeight,
    int? nextBottomPadding,
    int? nextScrollback,
    bool? nextUiToneFollowsTerminal,
  }) {
    final nextMode = nextUiTheme ?? uiTheme;
    final nextCursor = nextCursorStyle ?? cursorStyle;
    final nextLine = (nextLineHeight ?? lineHeight).clamp(0.9, 2.0).toDouble();
    final nextWeight = nextFontWeight ?? fontWeight;
    final nextPadding = (nextBottomPadding ?? bottomPadding).clamp(0, 64);
    final nextScroll = (nextScrollback ?? scrollback).clamp(1000, 100000);
    final nextColors = nextCustomColors ?? customColors;
    final nextCustom = nextCustomSkins ?? customSkins;
    final validColors =
        nextColors.isEmpty ||
        nextColors.entries.every(
          (entry) =>
              customColorLabels.containsKey(entry.key) &&
              entry.value >= 0 &&
              entry.value <= 0xffffffff,
        );
    final validSkin = nextSkin == null ||
        nextSkin == 'none' ||
        builtInSkins.containsKey(nextSkin) ||
        (nextSkin.startsWith('custom:') &&
            nextCustom.any((item) => item.id == nextSkin.substring(7)));
    if (!names.containsKey(nextPalette) ||
        nextSize < 10 ||
        nextSize > 28 ||
        nextLine < 0.9 ||
        nextLine > 2.0 ||
        !fontWeights.containsKey(nextWeight) ||
        !{'system', 'dark', 'light'}.contains(nextMode) ||
        !{'block', 'underline', 'verticalBar'}.contains(nextCursor) ||
        !validColors ||
        !validSkin ||
        nextCustom.length > 8 ||
        nextCustom.fold<int>(
              0,
              (total, item) => total + (item.background?.length ?? 0),
            ) >
            6 * 1024 * 1024) {
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
          'customSkins': nextCustom.map((item) => item.toJson()).toList(),
          'customColors': nextColors,
          'copyOnSelect': nextCopyOnSelect ?? copyOnSelect,
          'cursorStyle': nextCursor,
          'cursorBlink': nextCursorBlink ?? cursorBlink,
          'lineHeight': nextLine,
          'fontWeight': nextWeight,
          'bottomPadding': nextPadding,
          'scrollback': nextScroll,
          'uiToneFollowsTerminal':
              nextUiToneFollowsTerminal ?? uiToneFollowsTerminal,
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
      customSkins = List.unmodifiable(nextCustom);
      customColors = Map.unmodifiable(nextColors);
      copyOnSelect = nextCopyOnSelect ?? copyOnSelect;
      cursorStyle = nextCursor;
      cursorBlink = nextCursorBlink ?? cursorBlink;
      lineHeight = nextLine;
      fontWeight = nextWeight;
      bottomPadding = nextPadding;
      scrollback = nextScroll;
      uiToneFollowsTerminal =
          nextUiToneFollowsTerminal ?? uiToneFollowsTerminal;
      notifyListeners();
    });
    _pending = operation;
    return operation;
  }
}
