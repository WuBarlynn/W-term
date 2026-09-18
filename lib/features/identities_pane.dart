import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../app/identity_store.dart';
import '../app/errors.dart';

class IdentitiesPane extends StatefulWidget {
  final IdentityStore store;
  const IdentitiesPane({super.key, required this.store});
  @override
  State<IdentitiesPane> createState() => _IdentitiesPaneState();
}

class _IdentitiesPaneState extends State<IdentitiesPane> {
  List<SavedIdentity> items = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.store.identities();
      if (mounted) {
        setState(() {
          items = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit([SavedIdentity? identity]) async {
    final draft = await showDialog<IdentityDraft>(
      context: context,
      builder: (_) => IdentityEditor(identity: identity),
    );
    if (draft == null) return;
    if (!mounted) {
      draft.clear();
      return;
    }
    setState(() => busy = true);
    try {
      await widget.store.saveIdentity(draft);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      draft.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(SavedIdentity i) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除“${i.name}”？'),
        content: const Text('仍被主机使用的身份不能删除。'),
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
      await widget.store.deleteIdentity(i.id);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '身份与密钥',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: '添加身份',
              onPressed: busy ? null : () => edit(),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
      if (busy) const LinearProgressIndicator(minHeight: 2),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: items.isEmpty && !busy
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: Text('保存用户名与密码或私钥，多台主机可以共用一个身份。'),
              )
            : ListView(
                children: [
                  for (final i in items)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        i.kind == 'key' ? Icons.key_outlined : Icons.password,
                        size: 18,
                      ),
                      title: Text(i.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${i.username} · ${i.kind == 'key' ? '私钥' : '密码'}',
                      ),
                      trailing: PopupMenuButton<String>(
                        enabled: !busy,
                        tooltip: '身份操作：${i.name}',
                        onSelected: (v) => v == 'edit' ? edit(i) : remove(i),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text('凭证加密保存在本地保险库', style: TextStyle(fontSize: 11)),
      ),
    ],
  );
}

class IdentityEditor extends StatefulWidget {
  final SavedIdentity? identity;
  const IdentityEditor({super.key, this.identity});
  @override
  State<IdentityEditor> createState() => _IdentityEditorState();
}

class _IdentityEditorState extends State<IdentityEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.identity?.name),
      username = TextEditingController(text: widget.identity?.username);
  final password = TextEditingController(),
      keyText = TextEditingController(),
      passphrase = TextEditingController();
  late String kind = widget.identity?.kind ?? 'key';
  late bool replace = widget.identity == null;
  String? error;
  @override
  void dispose() {
    for (final c in [name, username, password, keyText, passphrase]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> importKey() async {
    try {
      final file = await openFile();
      if (file == null) return;
      if (await file.length() > 65536) {
        throw const FormatException('私钥不能超过 64 KiB');
      }
      final value = await file.readAsString();
      if (mounted) setState(() => keyText.text = value);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  void submit() {
    if (!form.currentState!.validate()) return;
    Navigator.pop(
      context,
      IdentityDraft(
        id: widget.identity?.id ?? '',
        name: name.text.trim(),
        username: username.text.trim(),
        kind: kind,
        replaceSecret: replace,
        password: replace && kind == 'password' ? password.text : '',
        privateKey: replace && kind == 'key' ? keyText.text : '',
        passphrase: replace && kind == 'key' ? passphrase.text : '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.identity == null ? '添加身份 / 密钥' : '编辑身份 / 密钥'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: '身份名称'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: username,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '用户名'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入用户名' : null,
              ),
              const SizedBox(height: 12),
              if (widget.identity != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('替换保存的凭证'),
                  subtitle: const Text('不勾选则保留已有密码或私钥'),
                  value: replace,
                  onChanged: (v) => setState(() => replace = v!),
                ),
              if (replace) ...[
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'password', label: Text('密码')),
                    ButtonSegment(value: 'key', label: Text('私钥')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (v) => setState(() => kind = v.first),
                ),
                const SizedBox(height: 12),
                if (kind == 'password')
                  TextFormField(
                    controller: password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: '保存的密码'),
                    validator: (v) => v == null || v.isEmpty ? '请输入密码' : null,
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: importKey,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('导入私钥文件'),
                  ),
                  TextFormField(
                    controller: keyText,
                    minLines: 3,
                    maxLines: 5,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: '私钥内容'),
                    validator: (v) =>
                        v == null || v.isEmpty ? '请输入或导入私钥' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passphrase,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '私钥口令（可选，加密保存）',
                    ),
                  ),
                ],
              ],
              if (error != null) Text(error!),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('保存')),
    ],
  );
}
