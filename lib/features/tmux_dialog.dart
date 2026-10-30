import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../src/rust/api/client.dart' as native;

class TmuxDialog extends StatefulWidget {
  final String connectionId, title;
  const TmuxDialog({
    super.key,
    required this.connectionId,
    required this.title,
  });
  @override
  State<TmuxDialog> createState() => _TmuxDialogState();
}

class _TmuxDialogState extends State<TmuxDialog> {
  static const _list =
      'tmux list-sessions -F "#{session_name}\\t#{session_windows}\\t#{session_attached}" 2>&1';
  List<(String, int, bool)> sessions = [];
  final selected = <String>{};
  bool loading = true;
  String? error;
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    load();
    refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!loading && mounted) load();
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final output = await native.runCommand(
        connectionId: widget.connectionId,
        command: _list,
      );
      final parsed = <(String, int, bool)>[];
      for (final line in const LineSplitter().convert(output)) {
        final parts = line.split('\t');
        if (parts.length < 3) continue;
        parsed.add((
          parts[0],
          int.tryParse(parts[1]) ?? 0,
          parts[2].trim() == '1',
        ));
      }
      if (!mounted) return;
      setState(() {
        sessions = parsed;
        selected.retainWhere(
          (name) => parsed.any((session) => session.$1 == name),
        );
        if (parsed.isEmpty && output.trim().isNotEmpty) error = output.trim();
      });
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _run(String command, String success) async {
    try {
      await native.runCommand(
        connectionId: widget.connectionId,
        command: command,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
      await load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  Future<void> create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建 tmux 会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '会话名称',
            helperText: '仅允许字母、数字、下划线、点和短横线',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    final value = name?.trim() ?? '';
    if (value.isEmpty) return;
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(value)) {
      setState(() => error = 'tmux 会话名称无效');
      return;
    }
    await _run("tmux new-session -d -s '$value'", '已创建 tmux 会话 $value');
  }

  Future<void> attach(String name) async {
    await native.writeTerminal(
      connectionId: widget.connectionId,
      bytes: utf8.encode("tmux attach -t '$name'\n"),
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> rename(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名 tmux 会话'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    final value = name?.trim() ?? '';
    if (value.isEmpty) return;
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(value)) {
      setState(() => error = 'tmux 会话名称无效');
      return;
    }
    await _run("tmux rename-session -t '$oldName' '$value'", '已重命名 tmux 会话');
  }

  Future<void> kill(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('结束 tmux 会话 $name？'),
        content: const Text('该会话中的程序会结束，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('结束'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run("tmux kill-session -t '$name'", '已结束 tmux 会话');
  }

  Future<void> killSelected() async {
    if (selected.isEmpty) return;
    final names = selected.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('结束 ${names.length} 个 tmux 会话？'),
        content: Text(
          '以下会话中的程序会结束，此操作不可撤销：\n\n'
          '${names.map((name) => '· $name').join('\n')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('全部结束'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => loading = true);
    try {
      for (final name in names) {
        await native.runCommand(
          connectionId: widget.connectionId,
          command: "tmux kill-session -t '$name'",
        );
      }
      selected.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已结束 ${names.length} 个 tmux 会话')),
        );
      }
      await load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('tmux 会话 · ${widget.title}'),
    content: SizedBox(
      width: 560,
      height: 420,
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                '每 5 秒自动刷新 · 勾选后可批量结束',
                style: TextStyle(fontSize: 12),
              ),
              if (selected.isNotEmpty)
                TextButton(
                  onPressed: loading ? null : killSelected,
                  child: Text('结束所选（${selected.length}）'),
                ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                onPressed: loading ? null : load,
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.icon(
                onPressed: loading ? null : create,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建'),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : sessions.isEmpty
                ? const Center(child: Text('没有运行中的 tmux 会话'))
                : ListView(
                    children: [
                      for (final (name, windows, attached) in sessions)
                        ListTile(
                          leading: Checkbox(
                            value: selected.contains(name),
                            onChanged: loading
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      selected.add(name);
                                    } else {
                                      selected.remove(name);
                                    }
                                  }),
                          ),
                          title: Row(
                            children: [
                              Icon(
                                attached ? Icons.link : Icons.link_off,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(name),
                            ],
                          ),
                          subtitle: Text(
                            '$windows 个窗口${attached ? ' · 已连接' : ''}',
                          ),
                          onTap: () => attach(name),
                          trailing: PopupMenuButton<String>(
                            tooltip: '会话操作',
                            onSelected: (value) {
                              if (value == 'attach') attach(name);
                              if (value == 'detach') {
                                _run(
                                  "tmux detach-client -s '$name' 2>/dev/null || true",
                                  '已分离 tmux 客户端',
                                );
                              }
                              if (value == 'rename') rename(name);
                              if (value == 'kill') kill(name);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'attach', child: Text('进入')),
                              PopupMenuItem(
                                value: 'detach',
                                child: Text('分离客户端'),
                              ),
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              PopupMenuItem(value: 'kill', child: Text('结束会话')),
                            ],
                          ),
                        ),
                    ],
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
