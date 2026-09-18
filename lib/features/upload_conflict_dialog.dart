import 'package:flutter/material.dart';

Future<String?> chooseUploadConflict(BuildContext context, String name) =>
    showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('服务器已有同名项目'),
        content: Text('“$name”已存在。替换会覆盖原文件；保留两个文件会自动添加序号。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, 'keepBoth'),
            child: const Text('保留两个文件'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'replace'),
            child: const Text('替换'),
          ),
        ],
      ),
    );
