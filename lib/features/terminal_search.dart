import 'package:flutter/material.dart';

/// Searches an in-memory snapshot, so incoming output cannot move results while
/// reading. No terminal contents are persisted or sent back to the remote host.
class TerminalSearch extends StatefulWidget {
  final List<String> Function() snapshot;
  const TerminalSearch({super.key, required this.snapshot});
  @override
  State<TerminalSearch> createState() => _TerminalSearchState();
}

class _TerminalSearchState extends State<TerminalSearch> {
  final query = TextEditingController();
  late List<String> lines = widget.snapshot();
  bool caseSensitive = false;
  @override
  void dispose() {
    query.dispose();
    lines = [];
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final needle = caseSensitive ? query.text : query.text.toLowerCase();
    final matches = needle.isEmpty
        ? <int>[]
        : [
            for (var i = 0; i < lines.length; i++)
              if ((caseSensitive ? lines[i] : lines[i].toLowerCase()).contains(
                needle,
              ))
                i,
          ];
    return AlertDialog(
      scrollable: true,
      title: const Text('搜索终端历史'),
      content: SizedBox(
        width: 660,
        height:
            ((MediaQuery.sizeOf(context).height -
                        MediaQuery.viewInsetsOf(context).bottom) *
                    0.65)
                .clamp(280.0, 540.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: query,
              autofocus: true,
              maxLength: 256,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '查找文本',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            Row(
              children: [
                Checkbox(
                  value: caseSensitive,
                  onChanged: (v) => setState(() => caseSensitive = v!),
                ),
                const Text('区分大小写'),
                const Spacer(),
                IconButton(
                  tooltip: '刷新历史快照',
                  onPressed: () => setState(() => lines = widget.snapshot()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Text('匹配 ${matches.length} 行 · 当前历史快照'),
            const SizedBox(height: 12),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        needle.isEmpty ? '输入关键词搜索，可选中结果复制' : '没有匹配的内容',
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (_, index) {
                        final line = matches[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 48,
                                child: Text(
                                  '${line + 1}',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                              Expanded(
                                child: SelectableText(
                                  lines[line],
                                  style: const TextStyle(
                                    fontFamily: 'Menlo',
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
