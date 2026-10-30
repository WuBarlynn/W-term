import 'package:flutter/material.dart';

import '../app/host_store.dart';
import '../app/identity_store.dart';
import '../app/errors.dart';
import '../app/proxy_store.dart';
import '../src/rust/api/proxy.dart' show ProxyProfile;
import 'identities_pane.dart';

class HostEditor extends StatefulWidget {
  final HostProfile? profile;
  final IdentityStore? credentials;
  final String initialGroup;
  final List<String> folders;
  final List<HostProfile> candidates;
  final ConnectionProxyStore? proxies;
  final List<ProxyProfile> proxyProfiles;
  final String proxyBinding;
  const HostEditor({
    super.key,
    this.profile,
    this.credentials,
    this.initialGroup = '',
    this.folders = const [],
    this.candidates = const [],
    this.proxies,
    this.proxyProfiles = const [],
    this.proxyBinding = '',
  });
  @override
  State<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends State<HostEditor> {
  final form = GlobalKey<FormState>();
  final password = TextEditingController();
  late final startup = TextEditingController(
    text: widget.profile?.startupCommand ?? '',
  );
  late final environment = TextEditingController(
    text: widget.profile?.environment.join('\n') ?? '',
  );
  List<SavedIdentity> identities = [];
  late List<String> jumpHostIds = [...?widget.profile?.jumpHostIds];
  late String proxyBinding = widget.proxyBinding;
  bool staleProxy = false;
  late String icon = widget.profile?.icon ?? '';
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
    if (proxyBinding.isNotEmpty &&
        proxyBinding != 'direct' &&
        !widget.proxyProfiles.any((p) => p.id == proxyBinding)) {
      staleProxy = true;
      proxyBinding = '';
    }
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

  bool _leadsBack(HostProfile candidate) {
    final targetId = widget.profile?.id;
    if (targetId == null) return false;
    final byId = {for (final h in widget.candidates) h.id: h};
    final seen = <String>{};
    bool walk(String id) {
      if (id == targetId) return true;
      if (!seen.add(id)) return true;
      final host = byId[id];
      if (host == null) return true;
      return host.jumpHostIds.any(walk);
    }

    return walk(candidate.id);
  }

  Future<void> addJumpHost() async {
    final currentId = widget.profile?.id;
    final available = widget.candidates
        .where(
          (h) =>
              h.id != currentId &&
              !jumpHostIds.contains(h.id) &&
              !_leadsBack(h),
        )
        .toList();
    if (available.isEmpty) {
      setState(() => error = '没有可添加的跳板主机；请先保存要作为跳板的主机');
      return;
    }
    final picked = await showDialog<HostProfile>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加跳板'),
        content: SizedBox(
          width: 380,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final host in available)
                ListTile(
                  dense: true,
                  title: Text(host.name),
                  subtitle: Text(
                    '${host.username}@${host.host}:${host.port}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, host),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        jumpHostIds.add(picked.id);
        error = null;
      });
    }
  }

  Future<void> submit() async {
    if (busy || loading || !form.currentState!.validate()) return;
    if (mode == 'saved' && !identities.any((i) => i.id == identityId)) {
      setState(() => error = '请选择有效身份');
      return;
    }
    final chosen = identities.where((i) => i.id == identityId).firstOrNull;
    late final HostProfile profile;
    try {
      profile = HostProfile(
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
        jumpHostIds: jumpHostIds,
        startupCommand: startup.text.trim(),
        environment: environment.text
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty && !line.startsWith('#'))
            .toList(),
        wiki: widget.profile?.wiki ?? '',
        icon: icon,
      );
    } on FormatException catch (e) {
      setState(() => error = e.message);
      return;
    }
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
      if (widget.proxies != null) {
        try {
          await widget.proxies!.setHostProxyBinding(saved.id, proxyBinding);
        } catch (e) {
          if (mounted) {
            setState(() => error = '主机已保存，但代理设置失败：${userFacingError(e)}');
          }
          return;
        }
      }
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
    startup.dispose();
    environment.dispose();
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
                const Divider(height: 24),
                DropdownButtonFormField<String>(
                  initialValue: icon,
                  decoration: const InputDecoration(labelText: '连接图标'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('默认服务器')),
                    DropdownMenuItem(value: 'terminal', child: Text('终端')),
                    DropdownMenuItem(value: 'database', child: Text('数据库')),
                    DropdownMenuItem(value: 'cloud', child: Text('云主机')),
                    DropdownMenuItem(value: 'code', child: Text('开发')),
                    DropdownMenuItem(value: 'globe', child: Text('网络')),
                    DropdownMenuItem(value: 'security', child: Text('安全')),
                    DropdownMenuItem(value: 'web', child: Text('网站')),
                    DropdownMenuItem(value: 'rocket', child: Text('构建')),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => icon = value ?? ''),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: startup,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '启动命令（可选）',
                    helperText: '连接成功后自动执行，行首会加空格以避免污染 shell 历史',
                  ),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (text.length > 16 * 1024) return '启动命令不能超过 16 KiB';
                    if (text.contains('\n') || text.contains('\r')) {
                      return '启动命令必须为单行';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: environment,
                  enabled: !busy,
                  autocorrect: false,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '环境变量（可选）',
                    helperText: '每行 KEY=VALUE；# 开头为注释；最多 64 项',
                  ),
                  validator: (value) {
                    final lines = (value ?? '')
                        .split('\n')
                        .map((line) => line.trim())
                        .where(
                          (line) => line.isNotEmpty && !line.startsWith('#'),
                        )
                        .toList();
                    if (lines.length > 64) return '环境变量最多 64 项';
                    final key = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');
                    for (final line in lines) {
                      if (line.length > 4096 || !key.hasMatch(line)) {
                        return '环境变量格式必须为 KEY=VALUE';
                      }
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
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
                if (widget.proxies != null) ...[
                  const Divider(height: 28),
                  Text(
                    '连接代理（仅第一跳）',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: proxyBinding,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      helperText: '代理只用于直连第一跳；跳板后的目标由上一跳访问。',
                      helperMaxLines: 2,
                    ),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('继承默认代理')),
                      const DropdownMenuItem(
                        value: 'direct',
                        child: Text('直连（不使用代理）'),
                      ),
                      for (final profile in widget.proxyProfiles)
                        DropdownMenuItem(
                          value: profile.id,
                          child: Text(
                            '${profile.name} · ${profile.mode.toUpperCase()} ${profile.host}:${profile.port}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() => proxyBinding = value!),
                  ),
                  if (staleProxy)
                    Text(
                      '此前指定的代理已不存在，已改为继承默认代理；请重新选择。',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
                if (widget.credentials != null) ...[
                  const Divider(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '跳板路线',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        '${jumpHostIds.length}/4',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (jumpHostIds.isEmpty)
                    Text(
                      '默认直接连接目标主机。可选择已保存主机按顺序作为跳板。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  for (var i = 0; i < jumpHostIds.length; i++)
                    Builder(
                      builder: (context) {
                        final host = widget.candidates
                            .where((h) => h.id == jumpHostIds[i])
                            .firstOrNull;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 12,
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          title: Text(host?.name ?? '主机已删除'),
                          subtitle: Text(
                            host == null
                                ? '请移除该项并重新选择跳板'
                                : '${host.username}@${host.host}:${host.port}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '上移',
                                icon: const Icon(Icons.arrow_upward, size: 18),
                                onPressed: busy || i == 0
                                    ? null
                                    : () => setState(() {
                                        final id = jumpHostIds.removeAt(i);
                                        jumpHostIds.insert(i - 1, id);
                                      }),
                              ),
                              IconButton(
                                tooltip: '下移',
                                icon: const Icon(
                                  Icons.arrow_downward,
                                  size: 18,
                                ),
                                onPressed: busy || i == jumpHostIds.length - 1
                                    ? null
                                    : () => setState(() {
                                        final id = jumpHostIds.removeAt(i);
                                        jumpHostIds.insert(i + 1, id);
                                      }),
                              ),
                              IconButton(
                                tooltip: '移除跳板',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: busy
                                    ? null
                                    : () => setState(
                                        () => jumpHostIds.removeAt(i),
                                      ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: busy || jumpHostIds.length >= 4
                          ? null
                          : addJumpHost,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加跳板'),
                    ),
                  ),
                  const Divider(height: 20),
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
