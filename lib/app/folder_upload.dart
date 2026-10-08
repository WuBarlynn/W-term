import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:desktop_drop/desktop_drop.dart';

class FolderUploadItem extends XFile {
  final String relativePath;
  final bool isDirectory;
  final int? parentIndex;
  final int scannedBytes;
  FolderUploadItem(
    super.path,
    this.relativePath,
    this.isDirectory,
    this.parentIndex, {
    this.scannedBytes = 0,
  });
}

class FolderScanCancelled implements Exception {
  const FolderScanCancelled();
}

/// Fully scan before changing the server. Links and special files are rejected.
Future<List<FolderUploadItem>> planFolderUpload(
  String root, {
  int maxEntries = 2000,
  int maxDepth = 32,
  bool Function()? isCancelled,
  void Function(int count)? onProgress,
}) async {
  void checkCancelled() {
    if (isCancelled?.call() ?? false) throw const FolderScanCancelled();
  }

  checkCancelled();
  final items = <FolderUploadItem>[];
  final normalized = Directory(root).absolute.path
      .replaceFirst(RegExp(r'/+$'), '');
  final rootName = normalized.split('/').last;
  Future<void> visit(
    String local,
    String relative,
    int? parent,
    int depth,
  ) async {
    checkCancelled();
    if (depth > maxDepth) throw const FormatException('文件夹层级超过限制');
    if (items.length >= maxEntries) {
      throw const FormatException('文件夹项目超过限制（最多 2000 项）');
    }
    final name = relative.split('/').last;
    if (name.isEmpty || name == '.' || name == '..' || name.contains('\x00')) {
      throw const FormatException('无效的文件夹项目名称');
    }
    final type = await FileSystemEntity.type(local, followLinks: false);
    checkCancelled();
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw FormatException('不支持符号链接或特殊文件：$relative');
    }
    final bytes = type == FileSystemEntityType.file
        ? await File(local).length()
        : 0;
    checkCancelled();
    final index = items.length;
    items.add(
      FolderUploadItem(
        local,
        relative,
        type == FileSystemEntityType.directory,
        parent,
        scannedBytes: bytes,
      ),
    );
    onProgress?.call(items.length);
    checkCancelled();
    if (type == FileSystemEntityType.directory) {
      final children = <FileSystemEntity>[];
      await for (final child in Directory(local).list(followLinks: false)) {
        checkCancelled();
        if (children.length + items.length >= maxEntries) {
          throw const FormatException('文件夹项目超过限制（最多 2000 项）');
        }
        children.add(child);
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        await visit(
          child.path,
          '$relative/${child.path.split('/').last}',
          index,
          depth + 1,
        );
      }
    }
  }

  if (await FileSystemEntity.type(normalized, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('请选择普通文件夹');
  }
  await visit(normalized, rootName, null, 0);
  checkCancelled();
  return List.unmodifiable(items);
}

/// Avoid starting only part of a mixed drop. Directory trees use their own batch.
DropItemDirectory? droppedFolder(List<DropItem> items) {
  final directories = items.whereType<DropItemDirectory>().toList();
  if (directories.isEmpty) return null;
  if (items.length != 1) {
    throw const FormatException('请一次拖入一个文件夹；多个文件可以一起拖入');
  }
  return directories.single;
}

String? validateUploadFolderName(String value) {
  if (value.trim().isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains('\\') ||
      value.runes.any((c) => c < 32 || (c >= 127 && c <= 159))) {
    return '请输入有效文件夹名称，不能包含路径分隔符或控制字符';
  }
  return null;
}

List<FolderUploadItem> renameUploadRoot(
  List<FolderUploadItem> items,
  String name,
) {
  final error = validateUploadFolderName(name);
  if (error != null) throw FormatException(error);
  if (items.isEmpty ||
      !items.first.isDirectory ||
      items.first.parentIndex != null) {
    throw const FormatException('无效的目录上传计划');
  }
  final root = items.first.relativePath;
  return List.unmodifiable(
    items.map((item) {
      if (item.relativePath != root &&
          !item.relativePath.startsWith('$root/')) {
        throw const FormatException('上传项目不属于此根目录');
      }
      return FolderUploadItem(
        item.path,
        '$name${item.relativePath.substring(root.length)}',
        item.isDirectory,
        item.parentIndex,
        scannedBytes: item.scannedBytes,
      );
    }),
  );
}

class FolderUploadSelection {
  final String targetName;
  final bool includeHidden;
  const FolderUploadSelection(this.targetName, {required this.includeHidden});
}

/// Hide dot-prefixed descendants, but preserve the explicitly selected root.
List<FolderUploadItem> selectFolderUploadItems(
  List<FolderUploadItem> items, {
  required bool includeHidden,
}) {
  if (includeHidden || items.isEmpty) return List.unmodifiable(items);
  final root = items.first.relativePath;
  final selected = <FolderUploadItem>[];
  final indices = <int, int>{};
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    if (index > 0) {
      if (!item.relativePath.startsWith('$root/')) {
        throw const FormatException('无效的目录上传计划');
      }
      final components = item.relativePath
          .substring(root.length + 1)
          .split('/');
      if (components.any((part) => part.startsWith('.'))) continue;
    }
    final parent = item.parentIndex;
    if (parent != null && !indices.containsKey(parent)) continue;
    indices[index] = selected.length;
    selected.add(
      FolderUploadItem(
        item.path,
        item.relativePath,
        item.isDirectory,
        parent == null ? null : indices[parent],
        scannedBytes: item.scannedBytes,
      ),
    );
  }
  return List.unmodifiable(selected);
}
