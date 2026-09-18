import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../app/temporary_directory.dart';

import 'package:share_plus/share_plus.dart';

import '../app/identity_store.dart';
import '../app/errors.dart';
import '../app/quick_unlock.dart';

class VaultSettings extends StatefulWidget {
  final VaultMaintenance store;
  const VaultSettings({super.key, required this.store});
  @override
  State<VaultSettings> createState() => _VaultSettingsState();
}

class _VaultSettingsState extends State<VaultSettings> {
  bool busy = false;
  String message = '';
  bool quickEnabled = false;
  final quick = QuickUnlock();
  @override
  void initState() {
    super.initState();
    quick
        .enabled()
        .then((v) {
          if (mounted) setState(() => quickEnabled = v);
        })
        .catchError((Object _) {});
  }

  Future<void> disableQuick() async {
    setState(() => busy = true);
    try {
      await quick.disable();
      if (mounted) {
        setState(() {
          quickEnabled = false;
          message = '已关闭快速解锁';
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(String kind) async {
    XFile? source;
    if (kind == 'restore') {
      source = await openFile();
      if (source == null || !mounted) return;
    }
    if (!mounted) return;
    final values = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PasswordDialog(kind: kind),
    );
    if (values == null || !mounted) return;
    setState(() {
      busy = true;
      message = '';
    });
    Directory? staging;
    try {
      if (kind == 'change') {
        await widget.store.changePassword(values[0], values[1]);
        if (mounted) {
          setState(() {
            quickEnabled = false;
            message = '主密码已修改。快速解锁需在下次使用主密码解锁时重新启用。原有备份仍使用各自的备份密码。';
          });
        }
      } else {
        staging = await createAppTemporaryDirectory('vault-backup-');
        final path = '${staging.path}/W-Term.wterm-backup';
        if (kind == 'export') {
          await widget.store.exportBackup(path, values[0]);
          if (!mounted) return;
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
            if (mounted) {
              setState(
                () => message = result.status == ShareResultStatus.dismissed
                    ? '已取消导出'
                    : '加密备份已交给分享面板，请确认保存位置。',
              );
            }
          } else {
            final target = await getSaveLocation(
              suggestedName: 'W-Term.wterm-backup',
            );
            if (target == null) return;
            await XFile(path).saveTo(target.path);
            if (mounted) setState(() => message = '加密备份已保存，包含主机、文件夹和身份凭证。');
          }
        } else {
          if (await source!.length() > 512 * 1024 * 1024) {
            throw const FormatException('备份文件不能超过 512 MiB');
          }
          await source.openRead().cast<List<int>>().pipe(
            File(path).openWrite(),
          );
          final count = await widget.store.restoreBackup(path, values[0]);
          if (mounted) {
            setState(() => message = '已恢复 $count 台主机。恢复的主机和身份标注为“恢复”，原数据保留。');
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => message = '操作失败：${userFacingError(e)}');
    } finally {
      for (var i = 0; i < values.length; i++) {
        values[i] = '';
      }
      if (staging != null) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          /* The OS may have already removed temporary files. */
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('保险库与备份'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('切换应用不会锁定保险库；完全退出后重新启动需要解锁。可在解锁页启用 Touch ID / Face ID。'),
            if (quickEnabled)
              TextButton.icon(
                onPressed: busy ? null : disableQuick,
                icon: const Icon(Icons.fingerprint),
                label: const Text('关闭快速解锁'),
              ),
            const SizedBox(height: 16),
            const Text('备份包含保存的密码和私钥，使用独立密码加密。请妥善保管备份文件与密码。'),
            const SizedBox(height: 16),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: busy ? null : () => action('change'),
              icon: const Icon(Icons.lock_reset),
              label: const Text('修改主密码'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: busy ? null : () => action('export'),
              icon: const Icon(Icons.save_alt),
              label: const Text('导出加密备份'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: busy ? null : () => action('restore'),
              icon: const Icon(Icons.restore),
              label: const Text('恢复加密备份'),
            ),
            if (busy) const LinearProgressIndicator(),
            if (message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(message),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}

class _PasswordDialog extends StatefulWidget {
  final String kind;
  const _PasswordDialog({required this.kind});
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final form = GlobalKey<FormState>();
  final current = TextEditingController(),
      password = TextEditingController(),
      confirm = TextEditingController();
  @override
  void dispose() {
    for (final c in [current, password, confirm]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.kind == 'change'
          ? '修改主密码'
          : widget.kind == 'export'
          ? '设置备份密码'
          : '输入备份密码',
    ),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.kind == 'change') ...[
                TextFormField(
                  controller: current,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '当前主密码'),
                  validator: (v) => v == null || v.isEmpty ? '请输入当前主密码' : null,
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: widget.kind == 'change' ? '新主密码' : '备份密码',
                ),
                validator: (v) => v == null || v.isEmpty
                    ? '请输入密码'
                    : widget.kind != 'restore' && v.runes.length < 12
                    ? '至少 12 个字符'
                    : null,
              ),
              if (widget.kind != 'restore') ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: confirm,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '再次输入密码'),
                  validator: (v) => v != password.text ? '两次密码不一致' : null,
                ),
              ] else
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('恢复会添加新的主机与身份，保留当前数据。重复恢复会产生额外副本。'),
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
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(
              context,
              widget.kind == 'change'
                  ? [current.text, password.text]
                  : [password.text],
            );
          }
        },
        child: const Text('确认'),
      ),
    ],
  );
}
