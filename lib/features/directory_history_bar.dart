import 'package:flutter/material.dart';

import '../app/directory_history.dart';

class DirectoryHistoryBar extends StatelessWidget {
  final DirectoryHistory history;
  final bool busy;
  final ValueChanged<int> onNavigate;
  const DirectoryHistoryBar({
    super.key,
    required this.history,
    required this.busy,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        tooltip: '后退目录',
        onPressed: busy || history.backIndex == null
            ? null
            : () => onNavigate(history.backIndex!),
        icon: const Icon(Icons.arrow_back, size: 18),
      ),
      IconButton(
        tooltip: '前进目录',
        onPressed: busy || history.forwardIndex == null
            ? null
            : () => onNavigate(history.forwardIndex!),
        icon: const Icon(Icons.arrow_forward, size: 18),
      ),
      const Spacer(),
      Text(
        '${history.index + 1} / ${history.paths.length}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
      PopupMenuButton<int>(
        tooltip: '目录历史',
        enabled: !busy && history.paths.isNotEmpty,
        icon: const Icon(Icons.history, size: 19),
        onSelected: onNavigate,
        itemBuilder: (_) => [
          for (var i = history.paths.length - 1; i >= 0; i--)
            CheckedPopupMenuItem(
              value: i,
              checked: i == history.index,
              child: Text(
                history.paths[i],
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    ],
  );
}
