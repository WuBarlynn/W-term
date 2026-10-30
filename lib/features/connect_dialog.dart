import '../app/errors.dart';
import '../app/ssh_key_material.dart';
import '../app/host_store.dart';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

class ConnectionRequest {
  final String host, username;
  final int port;
  String password, privateKey, passphrase;
  ConnectionRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.privateKey,
    required this.passphrase,
  });
  void clearSecrets() {
    password = '';
    privateKey = '';
    passphrase = '';
  }
}

class ConnectDialog extends StatefulWidget {
  final HostProfile? profile;
  final bool persistCredentials;
  const ConnectDialog({
    super.key,
    this.profile,
    this.persistCredentials = false,
  });
  @override
  State<ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<ConnectDialog> {
  final form = GlobalKey<FormState>();
  late final host = TextEditingController(text: widget.profile?.host);
  late final port = TextEditingController(
    text: '${widget.profile?.port ?? 22}',
  );
  late final username = TextEditingController(text: widget.profile?.username);
  final password = TextEditingController();
  final passphrase = TextEditingController();
  String key = '', keyName = '', certificate = '', certificateName = '';
  bool useKey = false;
  String? error;
  @override
  void dispose() {
    for (final c in [host, port, username, password, passphrase]) {
      c.clear();
      c.dispose();
    }
    key = '';
    certificate = '';
    super.dispose();
  }

  Future<void> importKey() async {
    try {
      final file = await openFile();
      if (file == null) return;
      if (await file.length() > 65536) {
        throw const FormatException('私钥文件不能超过 64 KiB');
      }
      final text = await file.readAsString();
      if (!mounted) return;
      setState(() {
        key = text;
        keyName = file.name;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
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

  void submit() {
    if (!form.currentState!.validate()) return;
    if (useKey && key.isEmpty) {
      setState(() => error = '请选择私钥文件');
      return;
    }
    Navigator.pop(
      context,
      ConnectionRequest(
        host: host.text.trim(),
        port: int.parse(port.text),
        username: username.text.trim(),
        password: useKey ? '' : password.text,
        privateKey: useKey ? keyWithSshCertificate(key, certificate) : '',
        passphrase: useKey ? passphrase.text : '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.profile == null ? '新建 SSH 连接' : '连接 ${widget.profile!.name}',
    ),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.persistCredentials
                    ? '密码或私钥将加密保存，下次可双击连接。密码留空时使用临时交互式连接，不保存凭证。'
                    : '直接连接服务器，凭证仅用于本次会话。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: host,
                      autofocus: true,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '主机地址',
                        hintText: 'IP 或域名',
                      ),
                      validator: (s) =>
                          s == null || s.trim().isEmpty ? '请输入主机地址' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 100,
                    child: TextFormField(
                      controller: port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '端口'),
                      validator: (s) {
                        final p = int.tryParse(s ?? '');
                        return p == null || p < 1 || p > 65535
                            ? '1–65535'
                            : null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: username,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '用户名'),
                validator: (s) =>
                    s == null || s.trim().isEmpty ? '请输入用户名' : null,
              ),
              const SizedBox(height: 20),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('密码'),
                    icon: Icon(Icons.password),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('私钥'),
                    icon: Icon(Icons.key_outlined),
                  ),
                ],
                selected: {useKey},
                onSelectionChanged: (s) => setState(() => useKey = s.first),
              ),
              const SizedBox(height: 20),
              if (useKey) ...[
                OutlinedButton.icon(
                  onPressed: importKey,
                  icon: const Icon(Icons.upload_file),
                  label: Text(keyName.isEmpty ? '选择私钥文件' : keyName),
                ),
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
                          '连接后证书随私钥使用，不单独保存',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          certificate = '';
                          certificateName = '';
                        }),
                        child: const Text('移除'),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: passphrase,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '私钥口令（可选）'),
                  onFieldSubmitted: (_) => submit(),
                ),
              ] else
                TextFormField(
                  controller: password,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    helperText: '仅交互式认证可留空；验证码在连接后填写，不在此保存。',
                    helperMaxLines: 2,
                  ),
                  onFieldSubmitted: (_) => submit(),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
      FilledButton(onPressed: submit, child: const Text('连接')),
    ],
  );
}
