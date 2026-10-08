import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/sync_store.dart';

class SyncConflictsDialog extends StatefulWidget {
  final SyncStore store;
  const SyncConflictsDialog({super.key, required this.store});
  @override
  State<SyncConflictsDialog> createState() => _SyncConflictsDialogState();
}

class _SyncConflictsDialogState extends State<SyncConflictsDialog> {
  SyncReview? review;
  final choices = <int, String>{};
  bool busy = true, confirmed = false, cancelling = false;
  String message = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await widget.store.syncConflicts();
      if (mounted) setState(() => review = r);
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    final r = review!;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final result = await widget.store.resolveSync(r.id, [
        for (var i = 0; i < r.items.length; i++)
          SyncChoice(r.items[i].kind, r.items[i].id, choices[i]!),
      ]);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
      // Applying choices can succeed before a network failure. Do not reapply an
      // old review; the pending batch is resumed from the main sync dialog.
      try {
        final p = await widget.store.syncSettings();
        if (mounted && p.pending) {
          setState(() {
            review = null;
            message += '\n选择已保存，请关闭此窗口并恢复待处理同步。';
          });
        }
      } catch (_) {}
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          cancelling = false;
        });
      }
    }
  }

  Future<void> cancel() async {
    setState(() => cancelling = true);
    try {
      await widget.store.cancelSync();
    } catch (e) {
      if (mounted) {
        setState(() {
          message = userFacingError(e);
          cancelling = false;
        });
      }
    }
  }

  String title(String kind) => switch (kind) {
    'host' => '主机',
    'identity' => '身份 / 密钥',
    'snippet' => '命令片段',
    'folders' => '文件夹树',
    _ => '记录',
  };
  Widget entry(SyncConflictEntry item, int index) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${index + 1}. ${title(item.kind)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '差异：${item.changedFields.isEmpty ? '身份关联需要一并确认' : item.changedFields.join('、')}',
          ),
          const SizedBox(height: 12),
          const Text('本机', style: TextStyle(fontWeight: FontWeight.w600)),
          Text(item.localSummary),
          const SizedBox(height: 10),
          const Text('远端', style: TextStyle(fontWeight: FontWeight.w600)),
          Text(item.remoteSummary),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('conflict-choice-$index'),
            initialValue: choices[index],
            isExpanded: true,
            decoration: const InputDecoration(labelText: '选择保留版本'),
            items: [
              DropdownMenuItem(
                value: 'local',
                child: Text(item.localDeleted ? '采用本机删除' : '保留本机'),
              ),
              DropdownMenuItem(
                value: 'remote',
                child: Text(item.remoteDeleted ? '采用远端删除' : '保留远端'),
              ),
            ],
            onChanged: busy
                ? null
                : (v) => setState(() {
                    choices[index] = v!;
                    confirmed = false;
                  }),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final r = review;
    final height = math.max(
      120.0,
      math.min(480.0, MediaQuery.sizeOf(context).height * 0.6),
    );
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: const Text('处理同步冲突'),
        content: SizedBox(
          width: 640,
          height: height,
          child: Column(
            children: [
              if (busy) const LinearProgressIndicator(),
              Expanded(
                child: r == null
                    ? SingleChildScrollView(
                        child: Text(
                          message.isNotEmpty
                              ? message
                              : busy
                              ? '正在读取冲突…'
                              : '没有待处理冲突。可关闭窗口后重新同步。',
                        ),
                      )
                    : ListView.builder(
                        itemCount: r.items.length + 2,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return const Padding(
                              padding: EdgeInsets.only(bottom: 16),
                              child: Text(
                                '逐项选择本机或远端版本。密码、私钥和命令内容隐藏。确认前双方数据保持不变；确认后所选版本将替换另一版本。',
                              ),
                            );
                          }
                          if (index <= r.items.length) {
                            return entry(r.items[index - 1], index - 1);
                          }
                          return Column(
                            children: [
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                value: confirmed,
                                onChanged: busy
                                    ? null
                                    : (v) => setState(() => confirmed = v!),
                                title: const Text('确认应用以上选择并继续同步'),
                              ),
                              if (message.isNotEmpty)
                                Text(
                                  message,
                                  key: const ValueKey('conflict-error'),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          if (busy && r != null)
            TextButton(
              onPressed: cancelling ? null : cancel,
              child: Text(cancelling ? '正在取消…' : '取消操作'),
            ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed:
                busy ||
                    r == null ||
                    r.items.isEmpty ||
                    choices.length != r.items.length ||
                    !confirmed
                ? null
                : apply,
            child: const Text('应用并同步'),
          ),
        ],
      ),
    );
  }
}
