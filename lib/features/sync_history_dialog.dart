import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/sync_store.dart';

class SyncHistoryDialog extends StatefulWidget {
  final SyncStore store;
  final String currentRevision;
  const SyncHistoryDialog({
    super.key,
    required this.store,
    required this.currentRevision,
  });
  @override
  State<SyncHistoryDialog> createState() => _SyncHistoryDialogState();
}

class _SyncHistoryDialogState extends State<SyncHistoryDialog> {
  List<SyncRevision> entries = const [];
  bool busy = true;
  String? restoring;
  String message = '';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final value = await widget.store.syncHistory();
      if (mounted) setState(() => entries = value);
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restore(SyncRevision entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复历史版本'),
        scrollable: true,
        content: Text(
          '将主机、身份、片段、文件夹与设置恢复到 ${_dateText(entry.committedAt)} 的版本。\n\n'
          '恢复会创建一个新的同步提交，不改写远端提交历史；本机尚未同步的修改会被拒绝。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复此版本'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      restoring = entry.revision;
      message = '';
    });
    try {
      final result = await widget.store.restoreSync(entry.revision);
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
    } finally {
      if (mounted) setState(() => restoring = null);
    }
  }

  static String _dateText(String value) {
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return value;
    String two(int number) => number.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('同步版本历史'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: busy
                  ? const Center(child: CircularProgressIndicator())
                  : entries.isEmpty
                  ? const Center(child: Text('暂无同步版本'))
                  : ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final current =
                            entry.revision == widget.currentRevision;
                        final working = restoring == entry.revision;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            current
                                ? Icons.check_circle
                                : Icons.history,
                            color: current
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(
                            _dateText(entry.committedAt),
                            style: const TextStyle(fontSize: 14),
                          ),
                          subtitle: Text(
                            '${entry.message}\n${entry.revision.substring(0, 12)}'
                            '${current ? ' · 当前版本' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          isThreeLine: true,
                          trailing: current
                              ? null
                              : TextButton(
                                  onPressed: busy || restoring != null
                                      ? null
                                      : () => restore(entry),
                                  child: working
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('恢复'),
                                ),
                        );
                      },
                    ),
            ),
            if (message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  message,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy || restoring != null ? null : load,
          child: const Text('刷新'),
        ),
        TextButton(
          onPressed: restoring != null
              ? null
              : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
