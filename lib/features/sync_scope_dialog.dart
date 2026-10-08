import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/sync_store.dart';

class SyncScopeDialog extends StatefulWidget {
  final SyncStore store;
  const SyncScopeDialog({super.key, required this.store});
  @override
  State<SyncScopeDialog> createState() => _SyncScopeDialogState();
}

class _SyncScopeDialogState extends State<SyncScopeDialog> {
  SyncScopeView? view;
  bool busy = true, confirmed = false, dirty = false;
  String error = '', query = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load([List<SyncScopeKey>? selection]) async {
    setState(() {
      busy = true;
      confirmed = false;
      error = '';
    });
    try {
      final next = await widget.store.syncScope(selection);
      if (mounted) {
        setState(() {
          view = next;
          dirty = selection != null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          view = null;
          error = userFacingError(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<SyncScopeKey> get selected => [
    for (final i in view!.items)
      if (i.selected) i.key,
  ];
  Future<void> save() async {
    final current = view!;
    final keys = selected;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.store.saveSyncScope(current.revision, keys);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // Require a fresh preview after a changed dependency or failed save.
      if (mounted) {
        setState(() {
          error = userFacingError(e);
          view = null;
          confirmed = false;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String kind(String value) => switch (value) {
    'host' => '主机',
    'identity' => '身份',
    _ => '命令片段',
  };
  @override
  Widget build(BuildContext context) {
    final current = view;
    final items =
        current?.items
            .where(
              (i) => '${i.summary} ${i.key.id} ${kind(i.key.kind)}'
                  .toLowerCase()
                  .contains(query.toLowerCase()),
            )
            .toList() ??
        [];
    final count = current?.items.where((i) => i.excluded).length ?? 0;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.all(16),
        title: const Text('仅本机范围'),
        content: SizedBox(
          width: 560,
          height: 540,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '勾选后仅在此设备保留。关联身份及共用该身份的主机会一起排除；文件夹树仍参与同步。已同步数据不能直接撤回，仓库历史与其他设备副本不会删除。',
              ),
              const SizedBox(height: 12),
              TextField(
                onChanged: (v) => setState(() => query = v),
                decoration: const InputDecoration(
                  labelText: '搜索主机、身份或片段',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 8),
              Text('仅本机 $count 项（含关联项）'),
              if (busy) const LinearProgressIndicator(),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, index) {
                    final i = items[index];
                    return CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${kind(i.key.kind)} · ${i.summary}${i.summary == '已删除 / 不存在' ? '（${i.key.id}）' : ''}',
                      ),
                      subtitle: Text(
                        i.selected
                            ? '已直接选择仅本机'
                            : i.excluded
                            ? '由关联主机或身份一起排除'
                            : i.published
                            ? '已同步 · 不支持直接撤回'
                            : '参与同步',
                      ),
                      value: i.selected,
                      onChanged: busy || (i.published && !i.selected)
                          ? null
                          : (value) {
                              final keys = selected.toSet();
                              if (value == true) {
                                keys.add(i.key);
                              } else {
                                keys.remove(i.key);
                              }
                              load(keys.toList());
                            },
                    );
                  },
                ),
              ),
              if (current != null && current.items.isEmpty)
                const Text('暂无主机、身份或片段'),
              if (current != null && current.blockedReason.isNotEmpty)
                Text(
                  current.blockedReason,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (current == null && !busy)
                TextButton(
                  onPressed: () => load(),
                  child: const Text('重新读取范围'),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('我已确认以上范围及关联影响'),
                value: confirmed,
                onChanged:
                    busy || current == null || current.blockedReason.isNotEmpty
                    ? null
                    : (v) => setState(() => confirmed = v!),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed:
                busy ||
                    !dirty ||
                    !confirmed ||
                    current == null ||
                    current.blockedReason.isNotEmpty
                ? null
                : save,
            child: const Text('保存范围'),
          ),
        ],
      ),
    );
  }
}
