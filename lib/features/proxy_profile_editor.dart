import 'package:flutter/material.dart';

import '../app/proxy_store.dart';
import '../src/rust/api/proxy.dart';
import 'proxy_test_dialog.dart';

class ProxyProfileEditorResult {
  final ProxyProfileInput profile;
  final String password;
  const ProxyProfileEditorResult(this.profile, this.password);
}

class ProxyProfileEditor extends StatefulWidget {
  final ProxyProfile? profile;
  final ConnectionProxyStore store;
  const ProxyProfileEditor({super.key, this.profile, required this.store});
  @override
  State<ProxyProfileEditor> createState() => _ProxyProfileEditorState();
}

class _ProxyProfileEditorState extends State<ProxyProfileEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.profile?.name);
  late final host = TextEditingController(text: widget.profile?.host);
  late final port = TextEditingController(
    text: '${widget.profile?.port ?? 3128}',
  );
  late final username = TextEditingController(text: widget.profile?.username);
  final password = TextEditingController();
  late String mode = widget.profile?.mode ?? 'http';
  late bool authenticate = widget.profile?.authenticate ?? false;
  bool busy = false;
  String? error;

  bool get canKeepPassword =>
      widget.profile?.passwordSaved == true &&
      authenticate &&
      widget.profile!.authenticate &&
      mode == widget.profile!.mode &&
      host.text.trim() == widget.profile!.host &&
      int.tryParse(port.text) == widget.profile!.port &&
      username.text == widget.profile!.username;

  ProxyDraft draft() => ProxyDraft(
    mode: mode,
    host: host.text.trim(),
    port: int.parse(port.text),
    authenticate: authenticate,
    username: authenticate ? username.text : '',
  );

  Future<void> test() async {
    if (busy || !form.currentState!.validate()) return;
    final saved = widget.profile;
    final usesSavedPassword =
        saved != null && canKeepPassword && password.text.isEmpty;
    await showDialog<void>(
      context: context,
      builder: (_) => ProxyTestDialog(
        title: '测试代理：${name.text.trim()}',
        run: (targetHost, targetPort) => usesSavedPassword
            ? widget.store.testProxyProfile(saved.id, targetHost, targetPort)
            : widget.store.testProxyDraft(
                draft(),
                password.text,
                targetHost,
                targetPort,
              ),
      ),
    );
  }

  void submit() {
    if (busy || !form.currentState!.validate()) return;
    final saved = widget.profile;
    Navigator.pop(
      context,
      ProxyProfileEditorResult(
        ProxyProfileInput(
          id: saved?.id ?? '',
          name: name.text.trim(),
          mode: mode,
          host: host.text.trim(),
          port: int.parse(port.text),
          authenticate: authenticate,
          username: authenticate ? username.text : '',
        ),
        authenticate ? password.text : '',
      ),
    );
  }

  @override
  void dispose() {
    password.clear();
    for (final controller in [name, host, port, username, password]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.profile == null ? '添加命名代理' : '编辑命名代理'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: name,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '代理名称'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '请输入代理名称' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: '连接方式'),
                  items: const [
                    DropdownMenuItem(
                      value: 'http',
                      child: Text('HTTP CONNECT'),
                    ),
                    DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
                  ],
                  onChanged: busy ? null : (v) => setState(() => mode = v!),
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
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
                  const SizedBox(height: 12),
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
                ],
                const SizedBox(height: 12),
                const Text(
                  '命名代理只保存在本机，不进入同步或备份。配置了命名代理的主机若在此设备找不到对应配置，会拒绝连接而不是回退直连。',
                  style: TextStyle(fontSize: 12),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
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
        OutlinedButton.icon(
          onPressed: busy ? null : test,
          icon: const Icon(Icons.network_check),
          label: const Text('测试'),
        ),
        FilledButton(onPressed: busy ? null : submit, child: const Text('保存')),
      ],
    ),
  );
}
