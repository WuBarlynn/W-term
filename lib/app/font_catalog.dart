import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'imported_fonts.dart';

/// Fonts shipped with the app. They are registered through pubspec and are
/// available even when the operating system has no CJK or coding font.
const monoFontFallback = <String>[
  'Cascadia Mono',
  'JetBrains Mono',
  'SF Mono',
  'Menlo',
  'Consolas',
  'monospace',
];

const bundledFonts = <String>['JetBrains Mono', 'Noto Sans SC'];

const commonUiFonts = <String>[
  'Noto Sans SC',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'SF Pro Text',
  'Segoe UI',
  'Helvetica Neue',
  'Arial',
  'Noto Sans',
  'Source Han Sans SC',
  'SimHei',
  'SimSun',
];

const commonTerminalFonts = <String>[
  'JetBrains Mono',
  'Cascadia Mono',
  'Cascadia Code',
  'Consolas',
  'SF Mono',
  'Menlo',
  'Monaco',
  'Fira Code',
  'Source Code Pro',
  'Noto Sans Mono CJK SC',
  'Sarasa Mono SC',
  'Courier New',
];

const commonCjkFonts = <String>[
  'Noto Sans SC',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Hiragino Sans GB',
  'Source Han Sans SC',
  'Noto Sans CJK SC',
  'Microsoft JhengHei',
  'SimHei',
  'SimSun',
];

const _channel = MethodChannel('dev.wterm/fonts');
List<String>? _systemFonts;

/// A synchronous, always-available catalog used before native enumeration
/// finishes (or when the platform channel is unavailable).
List<String> curatedFontFamilies() {
  final families = <String>{
    ...bundledFonts,
    ...commonUiFonts,
    ...commonTerminalFonts,
    ...commonCjkFonts,
  }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return families;
}

String platformDefaultUiFont() {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return 'Microsoft YaHei UI';
  }
  if (defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return 'PingFang SC';
  }
  return 'Noto Sans SC';
}

String platformDefaultTerminalFont() {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return 'Cascadia Mono';
  }
  if (defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return 'SF Mono';
  }
  return 'JetBrains Mono';
}

/// Enumerates installed font families through the native runner. Falls back to
/// a curated list when the platform channel is unavailable (for example in a
/// widget test or on an unsupported host).
Future<List<String>> availableFontFamilies() async {
  final families = <String>{...curatedFontFamilies(), ...importedFonts.names};
  var system = _systemFonts;
  if (system == null &&
      (Platform.isMacOS || Platform.isWindows || Platform.isIOS)) {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listFamilies');
      if (result != null) {
        system = [
          for (final value in result)
            if (value is String && value.trim().isNotEmpty) value.trim(),
        ];
        _systemFonts = system;
      }
    } catch (_) {
      // The bundled + curated list is still selectable.
    }
  }
  families.addAll(system ?? const []);
  final sorted = families.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return sorted;
}
