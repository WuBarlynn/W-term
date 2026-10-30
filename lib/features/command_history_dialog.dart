import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/command_history.dart';

class CommandHistoryDialog extends StatefulWidget {
  final CommandHistory history;
  const CommandHistoryDialog({super.key, required this.history});
  @override
  State<CommandHistoryDialog> createState() => _CommandHistoryDialogState();
}

class _CommandHistoryDialogState extends State<CommandHistoryDialog> {
  final search = TextEditingController();
  String query = '';

  String _time(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.history.entries.where((entry) {
      final text = '${entry.command} ${entry.host} ${entry.username}'
          .toLowerCase();
      return text.contains(query.trim().toLowerCase());
    }).toList();
    return AlertDialog(
      title: const Text('命令历史'),
      content: SizedBox(
        width: 680,
        height: 480,
        child: Column(
          children: [
            TextField(
              controller: search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索命令、主机或用户',
              ),
              onChanged: (value) => setState(() => query = value),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('暂无匹配的命令历史'))
                  : ListView.builder(
                      itemCount: entries.length.clamp(0, 300),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return ListTile(
                          dense: true,
                          title: Text(
                            entry.command,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                          subtitle: Text(
                            '${_time(entry.at)} · ${entry.username}@${entry.host}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '复制命令',
                            icon: const Icon(Icons.copy, size: 17),
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: entry.command),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('命令已复制')),
                                );
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.history.entries.isNotEmpty)
          TextButton(
            onPressed: () async {
              final clear = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空命令历史？'),
                  content: const Text('只删除本机历史记录，不影响任何终端会话。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('清空'),
                    ),
                  ],
                ),
              );
              if (clear == true) {
                await widget.history.clear();
                if (mounted) setState(() {});
              }
            },
            child: const Text('清空历史'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
