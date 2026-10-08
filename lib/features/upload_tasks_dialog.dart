import 'package:flutter/material.dart';

import '../app/upload_batch.dart';

class UploadTasksDialog extends StatefulWidget {
  final UploadBatch batch;
  final bool allowRetry;
  const UploadTasksDialog({
    super.key,
    required this.batch,
    this.allowRetry = false,
  });

  @override
  State<UploadTasksDialog> createState() => _UploadTasksDialogState();
}

class _UploadTasksDialogState extends State<UploadTasksDialog> {
  final search = TextEditingController();
  UploadState? filter;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.batch,
    builder: (context, _) {
      final batch = widget.batch;
      final visible = filterUploadTasks(
        batch.tasks,
        query: search.text,
        state: filter,
      );
      final counts = {for (final state in UploadState.values) state: 0};
      for (final task in batch.tasks) {
        counts[task.state] = counts[task.state]! + 1;
      }
      return AlertDialog(
        title: const Text('上传任务'),
        scrollable: true,
        content: SizedBox(
          width: 540,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                batch.destination,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              const Text(
                '取消剩余任务时，正在传输的文件会先完成。记录仅保留在当前会话，下一批上传会替换此列表。重试会重新读取原文件，并再次确认同名冲突。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '搜索文件名或路径',
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除任务搜索',
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            search.clear();
                            setState(() {});
                          },
                        ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '显示 ${visible.length} / ${batch.tasks.length} 项',
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '筛选任务状态',
                    onSelected: (value) => setState(
                      () => filter = value == 'all'
                          ? null
                          : UploadState.values.byName(value),
                    ),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'all', child: Text('全部状态')),
                      for (final state in UploadState.values)
                        PopupMenuItem(
                          value: state.name,
                          child: Text(uploadStateLabel(state)),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        filter == null
                            ? '全部状态 ▾'
                            : '${uploadStateLabel(filter!)} ▾',
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                UploadState.values
                    .where((state) => counts[state]! > 0)
                    .map(
                      (state) => '${uploadStateLabel(state)} ${counts[state]}',
                    )
                    .join(' · '),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 200,
                child: visible.isEmpty
                    ? const Center(child: Text('没有匹配任务'))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final task = visible[index];
                          final label = uploadStateLabel(task.state);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              task.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '$label${task.detail == null ? '' : ' · ${task.detail}'}',
                            ),
                            leading: Icon(switch (task.state) {
                              UploadState.waiting => Icons.schedule,
                              UploadState.running => Icons.upload,
                              UploadState.completed =>
                                Icons.check_circle_outline,
                              UploadState.failed => Icons.error_outline,
                              UploadState.cancelled => Icons.cancel_outlined,
                              UploadState.skipped => Icons.skip_next_outlined,
                            }),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          if (batch.active)
            TextButton(
              onPressed: batch.cancelRequested ? null : batch.cancelRemaining,
              child: Text(batch.cancelRequested ? '已请求取消' : '取消剩余任务'),
            ),
          if (widget.allowRetry &&
              !batch.active &&
              batch.failedIndices.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('重试全部失败项（${batch.failedIndices.length}）'),
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
