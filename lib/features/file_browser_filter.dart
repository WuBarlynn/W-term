import 'package:flutter/material.dart';

import '../src/rust/api/client.dart';

enum FileSort { name, size, modified }

List<RemoteEntry> filterRemoteEntries(
  List<RemoteEntry> entries, {
  required String query,
  required bool showHidden,
  required FileSort sort,
  required bool descending,
}) {
  final needle = query.trim().toLowerCase();
  final result = entries
      .where(
        (entry) =>
            (showHidden || !entry.name.startsWith('.')) &&
            entry.name.toLowerCase().contains(needle),
      )
      .toList();
  result.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    int order;
    switch (sort) {
      case FileSort.name:
        order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case FileSort.size:
        order = a.size.compareTo(b.size);
      case FileSort.modified:
        // Unknown timestamps stay last in either direction.
        if (a.modifiedAt == null && b.modifiedAt != null) return 1;
        if (a.modifiedAt != null && b.modifiedAt == null) return -1;
        order = (a.modifiedAt ?? 0).compareTo(b.modifiedAt ?? 0);
    }
    if (order == 0) order = a.name.compareTo(b.name);
    return descending ? -order : order;
  });
  return result;
}

String remoteModifiedLabel(int? seconds) {
  if (seconds == null) return '修改时间未知';
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

class FileBrowserControls extends StatelessWidget {
  final TextEditingController search;
  final bool showHidden, descending;
  final FileSort sort;
  final VoidCallback onFilterChanged, onToggleHidden, onToggleDirection;
  final ValueChanged<FileSort> onSort;
  const FileBrowserControls({
    super.key,
    required this.search,
    required this.showHidden,
    required this.descending,
    required this.sort,
    required this.onFilterChanged,
    required this.onToggleHidden,
    required this.onToggleDirection,
    required this.onSort,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 8, 8),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: search,
            onChanged: (_) => onFilterChanged(),
            decoration: InputDecoration(
              hintText: '搜索当前目录',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        search.clear();
                        onFilterChanged();
                      },
                    ),
            ),
          ),
        ),
        IconButton(
          tooltip: showHidden ? '隐藏点文件' : '显示隐藏文件',
          isSelected: showHidden,
          onPressed: onToggleHidden,
          icon: const Icon(Icons.visibility_off_outlined, size: 18),
          selectedIcon: const Icon(Icons.visibility_outlined, size: 18),
        ),
        PopupMenuButton<FileSort>(
          tooltip: '排序方式',
          initialValue: sort,
          icon: const Icon(Icons.sort, size: 18),
          onSelected: onSort,
          itemBuilder: (_) => [
            for (final item in [
              (FileSort.name, '名称'),
              (FileSort.size, '大小'),
              (FileSort.modified, '修改时间'),
            ])
              CheckedPopupMenuItem(
                value: item.$1,
                checked: sort == item.$1,
                child: Text(item.$2),
              ),
          ],
        ),
        IconButton(
          tooltip: descending ? '降序，点击切换升序' : '升序，点击切换降序',
          onPressed: onToggleDirection,
          icon: Icon(descending ? Icons.south : Icons.north, size: 18),
        ),
      ],
    ),
  );
}
