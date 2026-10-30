import 'dart:io';

import 'package:share_plus/share_plus.dart';

import '../app/temporary_directory.dart';
import 'private_key_export_dialog.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import '../app/identity_store.dart';
import '../app/ssh_key_material.dart';
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

  Future<void> generate() async {
    final store = widget.store;
    if (store is! KeyStore || busy) return;
    final details = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const GenerateKeyDialog(),
    );
    if (details == null || !mounted) return;
    setState(() => busy = true);
    try {
      final id = await (store as KeyStore).generateKey(details.$1, details.$2);
      await load();
      if (mounted) await showPublicKey(id);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> showPublicKey(String id) async {
    try {
      final value = await (widget.store as KeyStore).publicKey(id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('SSH 公钥'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '将此公钥添加到服务器对应用户的 ~/.ssh/authorized_keys，然后在主机设置中选择此身份。',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(value),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
            FilledButton.icon(
              onPressed: () async {
                try {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (c.mounted && mounted) {
                    Navigator.pop(c);
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('公钥已复制')));
                  }
                } catch (e) {
                  if (c.mounted) {
                    ScaffoldMessenger.of(
                      c,
                    ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
                  }
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('复制公钥'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  Future<void> exportKey(SavedIdentity identity) async {
    if (busy || widget.store is! PrivateKeyExportStore) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PrivateKeyExportDialog(
        onExport: (password) async {
          // Never stage an unencrypted private key in Dart or the filesystem.
          final staging = await createAppTemporaryDirectory(
            'private-key-export-',
          );
          try {
            final path = '${staging.path}/wterm-key';
            await (widget.store as PrivateKeyExportStore).exportPrivateKey(
              identity.id,
              path,
              password,
            );
            if (!mounted) return false;
            if (Platform.isIOS) {
              final box = context.findRenderObject() as RenderBox?;
              final result = await SharePlus.instance.share(
                ShareParams(
                  files: [XFile(path)],
                  sharePositionOrigin: box == null
                      ? null
                      : box.localToGlobal(Offset.zero) & box.size,
                ),
              );
              return result.status == ShareResultStatus.success;
            }
            final target = await getSaveLocation(suggestedName: 'wterm-key');
            if (target == null || !mounted) return false;
            await XFile(path).saveTo(target.path);
            return true;
          } finally {
            try {
              await staging.delete(recursive: true);
            } on FileSystemException {
              /* OS may already remove cache. */
            }
          }
        },
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Platform.isIOS ? '加密私钥已交给分享面板，请确认保存位置' : '加密私钥已保存'),
        ),
      );
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
            if (widget.store is KeyStore)
              IconButton(
                tooltip: '生成 SSH 密钥',
                onPressed: busy ? null : generate,
                icon: const Icon(Icons.key),
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
                        i.kind == 'key'
                            ? Icons.key_outlined
                            : i.kind == 'interactive'
                            ? Icons.question_answer_outlined
                            : Icons.password,
                        size: 18,
                      ),
                      title: Text(i.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${i.username} · ${i.kind == 'key'
                            ? '私钥'
                            : i.kind == 'interactive'
                            ? '仅交互式'
                            : '密码'}',
                      ),
                      trailing: PopupMenuButton<String>(
                        enabled: !busy,
                        tooltip: '身份操作：${i.name}',
                        onSelected: (v) {
                          if (v == 'edit') {
                            edit(i);
                          } else if (v == 'public') {
                            showPublicKey(i.id);
                          } else if (v == 'export') {
                            exportKey(i);
                          } else {
                            remove(i);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('编辑')),
                          if (i.kind == 'key' && widget.store is KeyStore)
                            const PopupMenuItem(
                              value: 'public',
                              child: Text('查看 / 复制公钥'),
                            ),
                          if (i.kind == 'key' &&
                              widget.store is PrivateKeyExportStore)
                            const PopupMenuItem(
                              value: 'export',
                              child: Text('导出加密私钥'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
                          ),
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
  String certificate = '', certificateName = '';
  String? error;
  @override
  void dispose() {
    for (final c in [name, username, password, keyText, passphrase]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> importCertificate() async {
    try {
      final file = await openFile();
      if (file == null) return;
      if (await file.length() > 32768) {
        throw const FormatException('证书不能超过 32 KiB');
      }
      final value = await file.readAsString();
      final issue = sshCertificateError(value);
      if (issue != null) throw FormatException(issue);
      if (mounted) {
        setState(() {
          certificate = value.trim();
          certificateName = file.name;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
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
        privateKey: replace && kind == 'key'
            ? keyWithSshCertificate(keyText.text, certificate)
            : '',
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
                    ButtonSegment(value: 'interactive', label: Text('仅交互式')),
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
                else if (kind == 'interactive')
                  const Text(
                    '不保存密码或私钥。每次连接（包括跳板）由服务器在打开终端前询问，回答不会进入保险库、同步或自动重放。',
                    style: TextStyle(fontSize: 12),
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
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: importCertificate,
                    icon: const Icon(Icons.verified_outlined),
                    label: Text(
                      certificateName.isEmpty
                          ? '导入 OpenSSH 证书（可选）'
                          : certificateName,
                    ),
                  ),
                  if (certificate.isNotEmpty)
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '证书将与私钥一起加密保存',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            certificate = '';
                            certificateName = '';
                          }),
                          child: const Text('移除证书'),
                        ),
                      ],
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

class GenerateKeyDialog extends StatefulWidget {
  const GenerateKeyDialog({super.key});
  @override
  State<GenerateKeyDialog> createState() => _GenerateKeyDialogState();
}

class _GenerateKeyDialogState extends State<GenerateKeyDialog> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final username = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    username.dispose();
    super.dispose();
  }

  void submit() {
    if (form.currentState!.validate()) {
      Navigator.pop(context, (name.text.trim(), username.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('生成 SSH 密钥'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('生成 Ed25519 密钥，私钥加密保存在本地保险库，可供多台主机共用。'),
              const SizedBox(height: 16),
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '身份名称'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: username,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '用户名'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入用户名' : null,
                onFieldSubmitted: (_) => submit(),
              ),
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
      FilledButton(onPressed: submit, child: const Text('生成并保存')),
    ],
  );
}
