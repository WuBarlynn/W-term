import 'package:flutter/material.dart';

import '../app/errors.dart';

/// The callback returns false when the platform save/share panel is cancelled.
class PrivateKeyExportDialog extends StatefulWidget {
  final Future<bool> Function(String password) onExport;
  const PrivateKeyExportDialog({super.key, required this.onExport});
  @override
  State<PrivateKeyExportDialog> createState() => _PrivateKeyExportDialogState();
}

class _PrivateKeyExportDialogState extends State<PrivateKeyExportDialog> {
  final form = GlobalKey<FormState>();
  final password = TextEditingController(),
      confirmation = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in [password, confirmation]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final saved = await widget.onExport(password.text);
      if (mounted) {
        if (saved) {
          Navigator.pop(context, true);
        } else {
          setState(() => error = '已取消保存，尚未完成导出');
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = '导出失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('导出加密私钥'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('以 OpenSSH 格式导出，设置独立口令以供其他 SSH 客户端使用。原有身份及登录口令不变。'),
              const SizedBox(height: 16),
              TextFormField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '导出口令（至少 12 个字符）'),
                validator: (v) =>
                    v == null || v.runes.length < 12 ? '口令至少需要 12 个字符' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: confirmation,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '再次输入导出口令'),
                validator: (v) => v != password.text ? '两次口令不一致' : null,
                onFieldSubmitted: (_) => submit(),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : submit,
          child: const Text('选择保存位置'),
        ),
      ],
    ),
  );
}
