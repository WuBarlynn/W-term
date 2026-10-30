import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/proxy_store.dart';
import '../src/rust/api/proxy.dart';
import 'proxy_profile_editor.dart';
import 'proxy_test_dialog.dart';

class ProxyDialog extends StatefulWidget {
  final ConnectionProxyStore store;
  const ProxyDialog({super.key, required this.store});
  @override
  State<ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<ProxyDialog> {
  final host = TextEditingController();
  final port = TextEditingController(text: '1080');
  final username = TextEditingController();
  final password = TextEditingController();
  final form = GlobalKey<FormState>();
  ProxySettings? saved;
  List<ProxyProfile> profiles = [];
  String mode = 'direct';
  bool authenticate = false, busy = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await widget.store.proxySettings();
      final items = await widget.store.proxyProfiles();
      if (!mounted) return;
      saved = value;
      profiles = items;
      mode = value.mode;
      host.text = value.host;
      port.text = '${value.port}';
      authenticate = value.authenticate;
      username.text = value.username;
    } catch (e) {
      if (mounted) error = userFacingError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reloadProfiles() async {
    try {
      final items = await widget.store.proxyProfiles();
      if (mounted) setState(() => profiles = items);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  bool get canKeepPassword =>
      saved?.passwordSaved == true &&
      mode == saved!.mode &&
      host.text.trim() == saved!.host &&
      int.tryParse(port.text) == saved!.port &&
      authenticate == saved!.authenticate &&
      username.text == saved!.username;

  Future<void> save({bool reset = false}) async {
    if (busy || (!reset && (saved == null || !form.currentState!.validate()))) {
      return;
    }
    if (reset) mode = 'direct';
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final task = widget.store.saveProxySettings(
        ProxySettings(
          mode: mode,
          host: mode == 'direct' ? '' : host.text.trim(),
          port: mode == 'direct' ? 1080 : int.parse(port.text),
          authenticate: mode != 'direct' && authenticate,
          username: mode != 'direct' && authenticate ? username.text : '',
          passwordSaved: false,
        ),
        mode != 'direct' && authenticate ? password.text : '',
      );
      password.clear();
      await task;
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> testDefault() async {
    await showDialog<void>(
      context: context,
      builder: (_) => ProxyTestDialog(
        title: '测试默认代理',
        run: (targetHost, targetPort) =>
            widget.store.testProxyGlobal(targetHost, targetPort),
      ),
    );
  }

  Future<void> editProfile([ProxyProfile? profile]) async {
    final result = await showDialog<ProxyProfileEditorResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProxyProfileEditor(profile: profile, store: widget.store),
    );
    if (result == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.saveProxyProfile(result.profile, result.password);
      await reloadProfiles();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> removeProfile(ProxyProfile profile) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除代理“${profile.name}”？'),
        content: const Text('仍被主机使用的命名代理不能删除。删除后需重新配置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.deleteProxyProfile(profile.id);
      await reloadProfiles();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> testProfile(ProxyProfile profile) async {
    await showDialog<void>(
      context: context,
      builder: (_) => ProxyTestDialog(
        title: '测试代理：${profile.name}',
        run: (targetHost, targetPort) =>
            widget.store.testProxyProfile(profile.id, targetHost, targetPort),
      ),
    );
  }

  Future<void> testAll() async {
    await showDialog<void>(
      context: context,
      builder: (_) => ProxyBatchTestDialog(
        profiles: profiles,
        run: (profile, targetHost, targetPort) =>
            widget.store.testProxyProfile(profile.id, targetHost, targetPort),
      ),
    );
  }

  @override
  void dispose() {
    password.clear();
    for (final controller in [host, port, username, password]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget profileTile(ProxyProfile profile) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.route_outlined, size: 18),
    title: Text(profile.name, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      '${profile.mode.toUpperCase()} · ${profile.host}:${profile.port}'
      '${profile.authenticate ? ' · ${profile.username}' : ''}'
      '${profile.passwordSaved ? ' · 密码已保存' : ''}',
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11),
    ),
    onTap: busy ? null : () => editProfile(profile),
    trailing: PopupMenuButton<String>(
      enabled: !busy,
      tooltip: '代理操作：${profile.name}',
      onSelected: (value) {
        if (value == 'edit') {
          editProfile(profile);
        } else if (value == 'test') {
          testProfile(profile);
        } else {
          removeProfile(profile);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('编辑')),
        PopupMenuItem(value: 'test', child: Text('测试')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('连接代理'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '默认代理只在本机生效，未单独指定的主机会继承它。已有会话保持当前连接；GitHub 同步不使用此代理。',
                ),
                const SizedBox(height: 16),
                if (busy) const LinearProgressIndicator(),
                if (saved != null) ...[
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: '连接方式'),
                    items: const [
                      DropdownMenuItem(value: 'direct', child: Text('直接连接')),
                      DropdownMenuItem(
                        value: 'http',
                        child: Text('HTTP CONNECT'),
                      ),
                      DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() => mode = value!),
                  ),
                  if (mode != 'direct') ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: host,
                      enabled: !busy,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '代理地址',
                        hintText: '域名或 IP，不含协议和端口',
                      ),
                      onChanged: (_) => setState(() {}),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '请输入代理地址' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: port,
                      enabled: !busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '代理端口'),
                      onChanged: (_) => setState(() {}),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        return n == null || n < 1 || n > 65535
                            ? '端口范围 1–65535'
                            : null;
                      },
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('用户名与密码认证'),
                      value: authenticate,
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              authenticate = value;
                              password.clear();
                            }),
                    ),
                    if (authenticate) ...[
                      TextFormField(
                        controller: username,
                        enabled: !busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(labelText: '代理用户名'),
                        onChanged: (_) => setState(() {}),
                        validator: (v) =>
                            v == null || v.isEmpty ? '请输入代理用户名' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: password,
                        enabled: !busy,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: '代理密码',
                          helperMaxLines: 3,
                          helperText: canKeepPassword
                              ? '已加密保存，留空保留原密码'
                              : '请输入密码；更改地址或用户名后须重新输入',
                        ),
                        validator: (v) =>
                            (v == null || v.isEmpty) && !canKeepPassword
                            ? '请输入代理密码'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '代理凭证在本机加密保存，不参与 GitHub 同步。HTTP Basic 和 SOCKS5 密码认证不会加密到代理这一段，请使用可信网络或本机代理。',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : testDefault,
                        icon: const Icon(Icons.network_check, size: 18),
                        label: const Text('测试已保存的默认代理'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '目标域名交由代理解析。代理失败不会自动改为直连，SSH 服务器指纹仍需核验。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ] else if (saved!.mode != 'direct') ...[
                    const SizedBox(height: 12),
                    const Text('保存后清除本机代理配置及其密码。'),
                  ],
                ],
                const Divider(height: 32),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '命名代理',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (profiles.isNotEmpty)
                      TextButton.icon(
                        onPressed: busy ? null : testAll,
                        icon: const Icon(Icons.playlist_add_check, size: 18),
                        label: const Text('测试全部'),
                      ),
                    TextButton.icon(
                      onPressed: busy || saved == null
                          ? null
                          : () => editProfile(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                const Text(
                  '命名代理只在本机保存，可在编辑主机时选择“直连”或指定代理；跳板路线只对第一跳应用。',
                  style: TextStyle(fontSize: 12),
                ),
                if (profiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '尚未创建命名代理。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                for (final profile in profiles) profileTile(profile),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  if (saved == null)
                    TextButton(
                      onPressed: busy ? null : load,
                      child: const Text('重试'),
                    ),
                  if (saved == null)
                    TextButton(
                      onPressed: busy ? null : () => save(reset: true),
                      child: const Text('清除代理并恢复直连'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy || saved == null ? null : save,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
