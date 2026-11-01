import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Folder icon choices keyed by folder path. The same built-in/Iconify values
/// used for host icons are stored here so both pickers stay consistent.
class FolderIconStore extends ChangeNotifier {
  final Future<File> Function() _file;
  FolderIconStore({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/folder-icons.json',
          ));

  static const defaultIcon = 'folder';
  static const maxEntries = 5000;
  Map<String, String> _icons = const {};
  Map<String, String> get icons => _icons;

  String iconFor(String path) => _icons[path] ?? defaultIcon;

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return;
      _icons = _validate(value);
      notifyListeners();
    } on FileSystemException {
      // Folder icons are optional; defaults remain usable.
    } on FormatException {
      // Ignore interrupted or manually edited files.
    }
  }

  Map<String, String> _validate(Map value) {
    final result = <String, String>{};
    for (final entry in value.entries) {
      final path = entry.key;
      final icon = entry.value;
      if (path is! String ||
          path.isEmpty ||
          path.length > 4096 ||
          icon is! String ||
          icon.length > 2048 ||
          result.length >= maxEntries) {
        continue;
      }
      result[path] = icon;
    }
    return Map.unmodifiable(result);
  }

  Future<void> setIcon(String path, String icon) async {
    if (path.isEmpty || path.length > 4096) {
      throw ArgumentError('无效的文件夹路径');
    }
    final next = Map<String, String>.from(_icons);
    if (icon.length > 2048) throw ArgumentError('无效的文件夹图标');
    if (icon.isEmpty || icon == defaultIcon) {
      next.remove(path);
    } else {
      next[path] = icon;
    }
    await _save(next);
  }

  Future<void> renamePrefix(String oldPath, String newPath) async {
    if (oldPath.isEmpty) return;
    final next = <String, String>{};
    for (final entry in _icons.entries) {
      if (entry.key == oldPath) {
        next[newPath] = entry.value;
      } else if (entry.key.startsWith('$oldPath/')) {
        next['$newPath${entry.key.substring(oldPath.length)}'] = entry.value;
      } else {
        next[entry.key] = entry.value;
      }
    }
    await _save(next);
  }

  Future<void> removePrefix(String path) async {
    if (path.isEmpty) return;
    final next = Map<String, String>.from(_icons)
      ..removeWhere(
        (key, _) => key == path || key.startsWith('$path/'),
      );
    await _save(next);
  }

  Map<String, String> toJson() => Map<String, String>.from(_icons);

  Future<void> applySynced(Object? raw) async {
    if (raw is! Map) return;
    await _save(_validate(raw));
  }

  Future<void> _save(Map<String, String> next) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(next), flush: true);
    await temporary.rename(file.path);
    _icons = Map.unmodifiable(Map<String, String>.from(next));
    notifyListeners();
  }
}

final folderIcons = FolderIconStore();
