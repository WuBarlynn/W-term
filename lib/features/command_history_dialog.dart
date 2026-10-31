import '../app/font_catalog.dart';

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
  String query = '', host = 'all', period = 'all';
  DateTimeRange? range;

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

  DateTime? get _start {
    final now = DateTime.now();
    return switch (period) {
      'today' => DateTime(now.year, now.month, now.day),
      '7d' => now.subtract(const Duration(days: 7)),
      '30d' => now.subtract(const Duration(days: 30)),
      'custom' => range?.start,
      _ => null,
    };
  }

  DateTime? get _end {
    if (period != 'custom' || range == null) return null;
    final end = range!.end;
    return DateTime(end.year, end.month, end.day, 23, 59, 59, 999);
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: range,
    );
    if (picked != null && mounted) {
      setState(() {
        range = picked;
        period = 'custom';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hosts = widget.history.entries.map((entry) => entry.host).toSet()
      ..removeWhere((value) => value.isEmpty);
    final sortedHosts = hosts.toList()..sort();
    final start = _start, end = _end;
    final entries = widget.history.entries.where((entry) {
      final text = '${entry.command} ${entry.host} ${entry.username}'
          .toLowerCase();
      if (!text.contains(query.trim().toLowerCase())) return false;
      if (host != 'all' && entry.host != host) return false;
      if (start != null && entry.at.isBefore(start)) return false;
      if (end != null && entry.at.isAfter(end)) return false;
      return true;
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
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    value: host,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: 'all', child: Text('全部主机')),
                      for (final value in sortedHosts)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: (value) => setState(() => host = value ?? 'all'),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: period,
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('全部时间')),
                    DropdownMenuItem(value: 'today', child: Text('今天')),
                    DropdownMenuItem(value: '7d', child: Text('近 7 天')),
                    DropdownMenuItem(value: '30d', child: Text('近 30 天')),
                    DropdownMenuItem(value: 'custom', child: Text('自定义日期')),
                  ],
                  onChanged: (value) {
                    if (value == 'custom') {
                      _pickRange();
                      return;
                    }
                    setState(() {
                      period = value ?? 'all';
                      range = null;
                    });
                  },
                ),
                const SizedBox(width: 8),
                if (period == 'custom' && range != null)
                  Text(
                    '${_time(range!.start).substring(0, 10)} — '
                    '${_time(range!.end).substring(0, 10)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                const Spacer(),
                Text(
                  '${entries.length} 条',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
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
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontFamilyFallback: monoFontFallback,
                            ),
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
