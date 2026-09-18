import 'package:flutter/material.dart';

import '../app/host_store.dart';
import '../app/identity_store.dart';
import '../app/errors.dart';
import 'identities_pane.dart';

class HostEditor extends StatefulWidget {
  final HostProfile? profile;
  final IdentityStore? credentials;
  final String initialGroup;
  final List<String> folders;
  const HostEditor({
    super.key,
    this.profile,
    this.credentials,
    this.initialGroup = '',
    this.folders = const [],
  });
  @override
  State<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends State<HostEditor> {
  final form = GlobalKey<FormState>();
  final password = TextEditingController();
  List<SavedIdentity> identities = [];
  late String mode = widget.profile?.identityId.isNotEmpty == true
      ? 'saved'
      : widget.credentials != null
      ? 'password'
      : 'prompt';
  late String identityId = widget.profile?.identityId ?? '';
  bool busy = false, loading = false;
  String? error;
  @override
  void initState() {
    super.initState();
    loadIdentities();
  }

  Future<void> loadIdentities() async {
    if (widget.credentials == null) return;
    setState(() => loading = true);
    try {
      final items = await widget.credentials!.identities();
      if (mounted) setState(() => identities = items);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> addIdentity() async {
    final draft = await showDialog<IdentityDraft>(
      context: context,
      builder: (_) => const IdentityEditor(),
    );
    if (draft == null) return;
    if (!mounted) {
      draft.clear();
      return;
    }
    setState(() => busy = true);
    try {
      final id = await widget.credentials!.saveIdentity(draft);
      await loadIdentities();
      if (mounted) {
        setState(() {
          identityId = id;
          mode = 'saved';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      draft.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (busy || loading || !form.currentState!.validate()) return;
    if (mode == 'saved' && !identities.any((i) => i.id == identityId)) {
      setState(() => error = '请选择有效身份');
      return;
    }
    final chosen = identities.where((i) => i.id == identityId).firstOrNull;
    final profile = HostProfile(
      id: widget.profile?.id ?? HostProfile.newId(),
      name: fields[0].text.trim(),
      host: fields[1].text.trim(),
      port: int.parse(fields[2].text),
      username: mode == 'saved' ? chosen!.username : fields[3].text.trim(),
      group: fields[4].text.trim(),
      tags: fields[5].text
          .split(RegExp('[,，]'))
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toSet()
          .toList(),
      favorite: widget.profile?.favorite ?? false,
      identityId: mode == 'saved' ? identityId : '',
    );
    final draft = mode == 'password'
        ? IdentityDraft(
            name: '${profile.name} · ${profile.username}',
            username: profile.username,
            kind: 'password',
            password: password.text,
          )
        : null;
    setState(() => busy = true);
    try {
      final saved = widget.credentials == null
          ? profile
          : await widget.credentials!.saveHost(profile, draft);
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      draft?.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  late final fields = [
    widget.profile?.name ?? '',
    widget.profile?.host ?? '',
    '${widget.profile?.port ?? 22}',
    widget.profile?.username ?? '',
    widget.profile?.group ?? widget.initialGroup,
    widget.profile?.tags.join(', ') ?? '',
  ].map((v) => TextEditingController(text: v)).toList();
  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    password.clear();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.profile == null ? '添加主机' : '编辑主机'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < fields.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextFormField(
                      controller: fields[i],
                      enabled: !busy && !(i == 3 && mode == 'saved'),
                      autocorrect: false,
                      keyboardType: i == 2
                          ? TextInputType.number
                          : TextInputType.text,
                      decoration: InputDecoration(
                        labelText: [
                          '名称',
                          '主机地址',
                          '端口',
                          '用户名',
                          '文件夹 / 分类（可选）',
                          '标签（逗号分隔）',
                        ][i],
                        suffixIcon: i == 4 && widget.folders.isNotEmpty
                            ? PopupMenuButton<String>(
                                tooltip: '选择文件夹',
                                icon: const Icon(Icons.folder_open, size: 18),
                                onSelected: (v) => fields[4].text = v,
                                itemBuilder: (_) => widget.folders
                                    .map(
                                      (f) => PopupMenuItem(
                                        value: f,
                                        child: Text(f),
                                      ),
                                    )
                                    .toList(),
                              )
                            : null,
                      ),
                      validator: (value) {
                        if (i == 3 && mode == 'saved') return null;
                        if (i == 4 &&
                            value != null &&
                            value.isNotEmpty &&
                            value
                                .split('/')
                                .any(
                                  (p) =>
                                      p.trim().isEmpty || p == '.' || p == '..',
                                )) {
                          return '使用 / 分隔文件夹，每段名称不能为空';
                        }
                        if (i < 4 && (value == null || value.trim().isEmpty)) {
                          return '此项不能为空';
                        }
                        if (i == 2) {
                          final p = int.tryParse(value ?? '');
                          if (p == null || p < 1 || p > 65535) {
                            return '端口必须为 1–65535';
                          }
                        }
                        return null;
                      },
                    ),
                  ),
                if (widget.credentials != null) ...[
                  if (loading) const LinearProgressIndicator(),
                  DropdownButtonFormField<String>(
                    key: ValueKey(mode),
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: '认证方式'),
                    items: const [
                      DropdownMenuItem(value: 'password', child: Text('保存密码')),
                      DropdownMenuItem(
                        value: 'saved',
                        child: Text('使用保存的身份 / 私钥'),
                      ),
                    ],
                    onChanged: busy ? null : (v) => setState(() => mode = v!),
                  ),
                  const SizedBox(height: 12),
                  if (mode == 'password')
                    TextFormField(
                      controller: password,
                      enabled: !busy,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '连接密码（加密保存）',
                      ),
                      validator: (v) => v == null || v.isEmpty ? '请输入密码' : null,
                    ),
                  if (mode == 'saved')
                    DropdownButtonFormField<String>(
                      key: ValueKey('$identityId-${identities.length}'),
                      initialValue: identities.any((i) => i.id == identityId)
                          ? identityId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '选择身份'),
                      items: identities
                          .map(
                            (i) => DropdownMenuItem(
                              value: i.id,
                              child: Text(
                                '${i.name} · ${i.username}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: busy
                          ? null
                          : (v) => setState(() {
                              identityId = v!;
                              fields[3].text = identities
                                  .firstWhere((i) => i.id == v)
                                  .username;
                            }),
                    ),
                  TextButton.icon(
                    onPressed: busy ? null : addIdentity,
                    icon: const Icon(Icons.key_outlined),
                    label: const Text('添加身份 / 私钥'),
                  ),
                ],
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy || loading ? null : submit,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
