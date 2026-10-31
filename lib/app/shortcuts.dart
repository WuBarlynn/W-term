import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ShortcutAction {
  final String id, label;
  const ShortcutAction(this.id, this.label);
}

const shortcutActions = <ShortcutAction>[
  ShortcutAction('new', '打开连接选择器'),
  ShortcutAction('close-tab', '关闭当前标签页'),
  ShortcutAction('prev-tab', '上一个标签页'),
  ShortcutAction('next-tab', '下一个标签页'),
  ShortcutAction('sessions', '已打开终端'),
  ShortcutAction('search', '终端内搜索'),
  ShortcutAction('files', '打开/关闭文件传输'),
  ShortcutAction('snippets', '显示/隐藏片段栏'),
  ShortcutAction('history', '打开命令历史'),
  ShortcutAction('settings', '打开设置'),
  ShortcutAction('local-terminal', '新建本地终端'),
  ShortcutAction('clear', '清空终端'),
  ShortcutAction('zoom-in', '放大终端字号'),
  ShortcutAction('zoom-out', '缩小终端字号'),
  ShortcutAction('zoom-reset', '重置终端字号'),
];

class ShortcutKey {
  final int keyId;
  final bool meta, control, shift, alt, enabled;
  const ShortcutKey({
    required this.keyId,
    this.meta = false,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.enabled = true,
  });

  Map<String, Object?> toJson() => {
    'keyId': keyId,
    'meta': meta,
    'control': control,
    'shift': shift,
    'alt': alt,
    'enabled': enabled,
  };

  static ShortcutKey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final keyId = raw['keyId'];
    if (keyId is! int || keyId <= 0) return null;
    bool flag(String key) => raw[key] == true;
    return ShortcutKey(
      keyId: keyId,
      meta: flag('meta'),
      control: flag('control'),
      shift: flag('shift'),
      alt: flag('alt'),
      enabled: raw['enabled'] != false,
    );
  }

  bool matches({
    required int pressedKeyId,
    required bool metaPressed,
    required bool controlPressed,
    required bool shiftPressed,
    required bool altPressed,
  }) =>
      enabled &&
      keyId == pressedKeyId &&
      meta == metaPressed &&
      control == controlPressed &&
      shift == shiftPressed &&
      alt == altPressed;

  String label({required bool apple}) {
    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    final name = key?.keyLabel ?? 'Key $keyId';
    final parts = <String>[
      if (meta) '⌘',
      if (control) apple ? '⌃' : 'Ctrl',
      if (shift) apple ? '⇧' : 'Shift',
      if (alt) apple ? '⌥' : 'Alt',
      name,
    ];
    return parts.join(apple ? '' : '+');
  }
}

class ShortcutSettings extends ChangeNotifier {
  final Future<File> Function() _file;
  final bool apple;
  final Map<String, ShortcutKey> bindings;
  Future<void> _pending = Future.value();

  ShortcutSettings({
    Future<File> Function()? file,
    bool? apple,
    Map<String, ShortcutKey>? initial,
  }) : apple =
           apple ??
           (defaultTargetPlatform == TargetPlatform.macOS ||
               defaultTargetPlatform == TargetPlatform.iOS),
       _file =
           file ??
           (() async => File(
             '${(await getApplicationSupportDirectory()).path}/shortcuts.json',
           )),
       bindings = initial ?? {} {
    if (initial == null) {
      bindings.addAll(defaultShortcutBindings(this.apple));
    }
  }

  static Map<String, ShortcutKey> defaultShortcutBindings(bool apple) => {
    'new': ShortcutKey(
      keyId: LogicalKeyboardKey.keyT.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'close-tab': ShortcutKey(
      keyId: LogicalKeyboardKey.keyW.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'prev-tab': ShortcutKey(
      keyId: LogicalKeyboardKey.bracketLeft.keyId,
      meta: apple,
      control: !apple,
      shift: true,
    ),
    'next-tab': ShortcutKey(
      keyId: LogicalKeyboardKey.bracketRight.keyId,
      meta: apple,
      control: !apple,
      shift: true,
    ),
    'sessions': ShortcutKey(
      keyId: LogicalKeyboardKey.keyO.keyId,
      meta: apple,
      control: !apple,
      shift: true,
    ),
    'search': ShortcutKey(
      keyId: LogicalKeyboardKey.keyF.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'files': ShortcutKey(
      keyId: LogicalKeyboardKey.keyU.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'snippets': ShortcutKey(
      keyId: LogicalKeyboardKey.keyP.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'history': ShortcutKey(
      keyId: LogicalKeyboardKey.keyY.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'settings': ShortcutKey(
      keyId: LogicalKeyboardKey.comma.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'local-terminal': ShortcutKey(
      keyId: LogicalKeyboardKey.keyN.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'clear': ShortcutKey(
      keyId: LogicalKeyboardKey.keyK.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'zoom-in': ShortcutKey(
      keyId: LogicalKeyboardKey.equal.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'zoom-out': ShortcutKey(
      keyId: LogicalKeyboardKey.minus.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
    'zoom-reset': ShortcutKey(
      keyId: LogicalKeyboardKey.digit0.keyId,
      meta: apple,
      control: !apple,
      shift: !apple,
    ),
  };

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map || value['bindings'] is! Map) return;
      final loaded = <String, ShortcutKey>{};
      for (final entry in (value['bindings'] as Map).entries) {
        final id = entry.key;
        final binding = ShortcutKey.fromJson(entry.value);
        if (id is String &&
            shortcutActions.any((action) => action.id == id) &&
            binding != null) {
          loaded[id] = binding;
        }
      }
      if (loaded.isNotEmpty) {
        bindings
          ..clear()
          ..addAll({...defaultShortcutBindings(apple), ...loaded});
        notifyListeners();
      }
    } catch (_) {
      // A broken shortcut file falls back to defaults.
    }
  }

  Future<void> set(String action, ShortcutKey binding) {
    bindings[action] = binding;
    notifyListeners();
    return _save();
  }

  Future<void> reset() {
    bindings
      ..clear()
      ..addAll(defaultShortcutBindings(apple));
    notifyListeners();
    return _save();
  }

  Future<void> _save() {
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'bindings': {
            for (final entry in bindings.entries)
              entry.key: entry.value.toJson(),
          },
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    });
    _pending = operation;
    return operation;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'bindings': {
      for (final entry in bindings.entries) entry.key: entry.value.toJson(),
    },
  };

  Future<void> applySynced(Object? raw) async {
    if (raw is! Map || raw['bindings'] is! Map) return;
    final next = defaultShortcutBindings(apple);
    for (final entry in (raw['bindings'] as Map).entries) {
      final id = entry.key;
      final binding = ShortcutKey.fromJson(entry.value);
      if (id is String &&
          shortcutActions.any((action) => action.id == id) &&
          binding != null) {
        next[id] = binding;
      }
    }
    bindings
      ..clear()
      ..addAll(next);
    notifyListeners();
    await _save();
  }

  String? match({
    required int keyId,
    required bool metaPressed,
    required bool controlPressed,
    required bool shiftPressed,
    required bool altPressed,
  }) {
    for (final entry in bindings.entries) {
      if (entry.value.matches(
        pressedKeyId: keyId,
        metaPressed: metaPressed,
        controlPressed: controlPressed,
        shiftPressed: shiftPressed,
        altPressed: altPressed,
      )) {
        return entry.key;
      }
    }
    return null;
  }
}

final shortcutSettings = ShortcutSettings();
