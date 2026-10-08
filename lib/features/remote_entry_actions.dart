import 'package:flutter/material.dart';

class RemoteEntryActions extends StatelessWidget {
  final bool enabled, isDirectory;
  final VoidCallback onRename, onDelete, onDownload;
  final VoidCallback? onPermissions, onEdit;
  const RemoteEntryActions({
    super.key,
    required this.enabled,
    required this.isDirectory,
    required this.onRename,
    required this.onDelete,
    required this.onDownload,
    this.onPermissions,
    this.onEdit,
  });
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    enabled: enabled,
    tooltip: '文件操作',
    onSelected: (action) {
      if (action == 'rename') onRename();
      if (action == 'delete') onDelete();
      if (action == 'download') onDownload();
      if (action == 'permissions') onPermissions?.call();
      if (action == 'edit') onEdit?.call();
    },
    itemBuilder: (_) => [
      if (!isDirectory)
        const PopupMenuItem(value: 'download', child: Text('下载')),
      if (onEdit != null)
        const PopupMenuItem(value: 'edit', child: Text('编辑文本')),
      const PopupMenuItem(value: 'rename', child: Text('重命名')),
      if (onPermissions != null)
        const PopupMenuItem(value: 'permissions', child: Text('权限')),
      const PopupMenuItem(value: 'delete', child: Text('删除')),
    ],
  );
}

Future<bool> confirmRemoteDelete(
  BuildContext context, {
  required String name,
  required bool isDirectory,
  required bool isSymlink,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除远程项目？'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            const SizedBox(height: 12),
            Text(
              isSymlink
                  ? '仅删除链接本身，保留链接指向的文件。'
                  : isDirectory
                  ? '仅删除空文件夹，非空文件夹会保留。'
                  : '文件将从服务器删除，无法在应用中撤销。',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ) ??
    false;
