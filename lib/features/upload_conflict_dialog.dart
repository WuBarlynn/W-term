import 'package:flutter/material.dart';

import '../app/upload_conflict.dart';

Future<UploadConflictChoice?> chooseUploadConflict(
  BuildContext context,
  String name,
) {
  var applyToRemaining = false;
  return showDialog<UploadConflictChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('服务器已有同名项目'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('“$name”已存在。替换会覆盖原文件；保留两个文件会自动添加序号；跳过会保留服务器已有项目。'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: applyToRemaining,
              title: const Text('对本批后续冲突使用相同选择'),
              subtitle: const Text('仅限本次上传，失败重试时重新询问'),
              onChanged: (value) =>
                  setState(() => applyToRemaining = value ?? false),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              UploadConflictChoice(
                UploadConflictAction.skip,
                applyToRemaining: applyToRemaining,
              ),
            ),
            child: const Text('跳过'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(
              context,
              UploadConflictChoice(
                UploadConflictAction.keepBoth,
                applyToRemaining: applyToRemaining,
              ),
            ),
            child: const Text('保留两个文件'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              UploadConflictChoice(
                UploadConflictAction.replace,
                applyToRemaining: applyToRemaining,
              ),
            ),
            child: const Text('替换'),
          ),
        ],
      ),
    ),
  );
}
