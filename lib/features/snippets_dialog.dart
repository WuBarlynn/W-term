import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/snippet_store.dart';
import '../app/errors.dart';
import '../app/snippet_catalog.dart';
import '../app/pinned_commands.dart';

class SnippetsDialog extends StatefulWidget {
  final SnippetStore store;
  final bool allowInsert;
  const SnippetsDialog({
    super.key,
    required this.store,
    this.allowInsert = true,
  });
  @override
  State<SnippetsDialog> createState() => _SnippetsDialogState();
}

class _SnippetsDialogState extends State<SnippetsDialog> {
  List<CommandSnippet> entries = [];
  String query = '';
  String? error;
  bool busy = true;
  bool market = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => busy = true);
    try {
      final result = await widget.store.readSnippets();
      if (mounted) {
        setState(() {
          entries = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addCatalog(SnippetCatalogEntry entry) async {
    setState(() => busy = true);
    try {
      await widget.store.saveSnippet('', entry.name, entry.command);
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已添加片段：${entry.name}')));
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit([CommandSnippet? entry]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SnippetEditor(
        entry: entry,
        onSave: (name, command) =>
            widget.store.saveSnippet(entry?.id ?? '', name, command),
      ),
    );
    if (saved == true && mounted) await load();
  }

  Future<void> copy(CommandSnippet entry) async {
    try {
      await Clipboard.setData(ClipboardData(text: entry.command));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('片段已复制')));
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  Future<void> remove(CommandSnippet entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除“${entry.name}”？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.store.deleteSnippet(entry.id);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _catalogList(int ignored) {
    final needle = query.trim().toLowerCase();
    final entries = snippetCatalog
        .where(
          (entry) => '${entry.name} ${entry.category} ${entry.command}'
              .toLowerCase()
              .contains(needle),
        )
        .toList();
    if (entries.isEmpty) return const Center(child: Text('没有匹配的官方片段'));
    return ListView(
      children: [
        for (final entry in entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry.name),
            subtitle: Text(
              '${entry.category} · ${entry.command}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '添加到我的片段',
              onPressed: busy ? null : () => addCatalog(entry),
              icon: const Icon(Icons.add_circle_outline, size: 18),
            ),
            onTap: busy ? null : () => addCatalog(entry),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = entries
        .where(
          (s) => '${s.name}\n${s.command}'.toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .toList();
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('命令片段')),
            IconButton(
              tooltip: '刷新片段',
              onPressed: busy ? null : load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        content: SizedBox(
          width: 560,
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.allowInsert
                    ? '单行片段加密保存在保险库。插入会追加到当前终端输入，不附加回车。'
                    : '片段加密保存在保险库，可在未连接服务器时管理。点击片段编辑，菜单可复制命令。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('我的片段')),
                  ButtonSegment(value: true, label: Text('官方精选')),
                ],
                selected: {market},
                onSelectionChanged: (value) =>
                    setState(() => market = value.first),
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: '搜索片段'),
                onChanged: (v) => setState(() => query = v),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: market
                    ? _catalogList(visible.length)
                    : visible.isEmpty
                    ? const Center(child: Text('没有匹配片段'))
                    : ListView(
                        children: [
                          for (final entry in visible)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                entry.command,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: PopupMenuButton<String>(
                                enabled: !busy,
                                tooltip: '片段操作：${entry.name}',
                                onSelected: (v) {
                                  if (v == 'edit') {
                                    edit(entry);
                                  } else if (v == 'copy') {
                                    copy(entry);
                                  } else if (v == 'pin') {
                                    pinnedCommands.pin(
                                      PinnedCommand(
                                        name: entry.name,
                                        command: entry.command,
                                      ),
                                    );
                                  } else {
                                    remove(entry);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'copy',
                                    child: Text('复制命令'),
                                  ),
                                  PopupMenuItem(
                                    value: 'pin',
                                    child: Text('固定到命令条'),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text('编辑'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除'),
                                  ),
                                ],
                              ),
                              onTap: busy
                                  ? null
                                  : () async {
                                      if (!widget.allowInsert) {
                                        await edit(entry);
                                        return;
                                      }
                                      final yes = await showDialog<bool>(
                                        context: context,
                                        builder: (c) => AlertDialog(
                                          title: const Text('插入命令片段？'),
                                          scrollable: true,
                                          content: SelectableText(
                                            entry.command,
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(c, false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(c, true),
                                              child: const Text('插入，不执行'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (yes == true &&
                                          context.mounted &&
                                          validateSnippetCommand(
                                                entry.command,
                                              ) ==
                                              null) {
                                        Navigator.pop(context, entry.command);
                                      }
                                    },
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: busy ? null : () => edit(),
            child: const Text('新建片段'),
          ),
        ],
      ),
    );
  }
}

class _SnippetEditor extends StatefulWidget {
  final CommandSnippet? entry;
  final Future<void> Function(String name, String command) onSave;
  const _SnippetEditor({this.entry, required this.onSave});
  @override
  State<_SnippetEditor> createState() => _SnippetEditorState();
}

class _SnippetEditorState extends State<_SnippetEditor> {
  late final name = TextEditingController(text: widget.entry?.name),
      command = TextEditingController(text: widget.entry?.command);
  final form = GlobalKey<FormState>();
  bool saving = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    command.clear();
    command.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave(name.text.trim(), command.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(widget.entry == null ? '新建片段' : '编辑片段'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                enabled: !saving,
                maxLength: 256,
                decoration: const InputDecoration(labelText: '名称'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入名称' : null,
              ),
              TextFormField(
                controller: command,
                enabled: !saving,
                minLines: 3,
                maxLines: 6,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '单行命令'),
                validator: (v) => validateSnippetCommand(v ?? ''),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (saving) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: saving ? null : save, child: const Text('保存')),
      ],
    ),
  );
}
