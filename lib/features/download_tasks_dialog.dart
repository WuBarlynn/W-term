import 'package:flutter/material.dart';

import '../app/download_batch.dart';

class DownloadTasksDialog extends StatelessWidget {
  final DownloadBatch batch;
  const DownloadTasksDialog({super.key, required this.batch});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: batch,
    builder: (context, _) {
      final completed = batch.count(DownloadState.completed);
      final failed = batch.count(DownloadState.failed);
      final waiting = batch.count(DownloadState.waiting);
      return AlertDialog(
        title: const Text('下载队列'),
        content: SizedBox(
          width: 560,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                batch.destination,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '完成 $completed · 失败 $failed · 等待 $waiting',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: batch.tasks.length,
                  itemBuilder: (context, index) {
                    final task = batch.tasks[index];
                    final icon = switch (task.state) {
                      DownloadState.waiting => Icons.schedule,
                      DownloadState.running => Icons.downloading,
                      DownloadState.completed => Icons.check_circle,
                      DownloadState.failed => Icons.error_outline,
                      DownloadState.cancelled => Icons.cancel_outlined,
                    };
                    final color = switch (task.state) {
                      DownloadState.completed => Colors.green,
                      DownloadState.failed => Theme.of(
                        context,
                      ).colorScheme.error,
                      DownloadState.running => Theme.of(
                        context,
                      ).colorScheme.primary,
                      _ => null,
                    };
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        task.isDirectory ? Icons.folder : icon,
                        color: color,
                        size: 20,
                      ),
                      title: Text(task.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          downloadStateLabel(task.state),
                          if (task.detail != null && task.detail!.isNotEmpty)
                            task.detail!,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
              const Text(
                '取消剩余任务时，正在下载的文件会先完成；记录仅保留在当前会话。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          if (batch.active && !batch.cancelRequested)
            TextButton(
              onPressed: batch.cancelRemaining,
              child: const Text('取消剩余'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
