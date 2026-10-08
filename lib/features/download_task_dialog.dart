import 'package:flutter/material.dart';

import '../app/download_task.dart';

class DownloadTaskDialog extends StatelessWidget {
  final DownloadTask task;
  final bool allowRetry;
  const DownloadTaskDialog({
    super.key,
    required this.task,
    this.allowRetry = true,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: task,
    builder: (context, _) => AlertDialog(
      title: const Text('最近下载'),
      scrollable: true,
      content: SizedBox(
        width: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(task.name),
            const SizedBox(height: 8),
            SelectableText(task.remotePath),
            const SizedBox(height: 12),
            Text(task.status),
            if (task.bytes != null) Text('已接收 ${task.bytes} 字节'),
            if (task.active) const LinearProgressIndicator(),
            if (task.error != null) SelectableText(task.error!),
            if (task.cleanupWarning != null)
              SelectableText(task.cleanupWarning!),
            const SizedBox(height: 12),
            const Text(
              '重新下载会读取服务器当前内容，并再次选择保存或分享。仅保留当前会话的最近一次记录。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        if (!task.active && allowRetry)
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新下载'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
