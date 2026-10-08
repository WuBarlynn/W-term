import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/sync_store.dart';

class SyncRotationDialog extends StatefulWidget {
  final SyncStore store;
  const SyncRotationDialog({super.key, required this.store});
  @override
  State<SyncRotationDialog> createState() => _SyncRotationDialogState();
}

class _SyncRotationDialogState extends State<SyncRotationDialog> {
  final password = TextEditingController();
  final repeat = TextEditingController();
  final code = TextEditingController();
  SyncRotation? status;
  bool busy = true,
      cancelling = false,
      understand = false,
      saved = false,
      discard = false;
  String recoveryCode = '', message = '';

  @override
  void initState() {
    super.initState();
    refreshInitial();
  }

  Future<void> refreshInitial() async {
    try {
      status = await widget.store.rotationStatus();
    } catch (e) {
      message = userFacingError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(Future<String> Function() operation) async {
    setState(() {
      busy = true;
      cancelling = false;
      message = '';
    });
    try {
      final result = await operation();
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
    } finally {
      // Fail closed if refresh fails: stale state must not enable another action.
      SyncRotation? next;
      try {
        next = await widget.store.rotationStatus();
      } catch (e) {
        if (mounted) setState(() => message += '\n${userFacingError(e)}');
      }
      if (mounted) {
        setState(() {
          if (next?.batchId != status?.batchId && recoveryCode.isEmpty) {
            saved = false;
          }
          status = next;
          busy = false;
          cancelling = false;
          discard = false;
          if (next == null || !next.active || next.recoveryConfirmed) {
            recoveryCode = '';
          }
        });
      }
    }
  }

  Future<void> cancel() async {
    setState(() => cancelling = true);
    try {
      await widget.store.cancelSync();
    } catch (e) {
      if (mounted) {
        setState(() {
          message = userFacingError(e);
          cancelling = false;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final c in [password, repeat, code]) {
      c.clear();
      c.dispose();
    }
    recoveryCode = '';
    super.dispose();
  }

  Widget field(String label, TextEditingController controller) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: TextField(
      controller: controller,
      enabled: !busy,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = status;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: const Text('轮换同步密钥'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '为同步数据生成新密钥、独立同步口令和恢复码。其他设备需要重新接入；本机保险库主密码不变。旧仓库历史和已下载副本不会被撤销。',
                ),
                const SizedBox(height: 16),
                if (s != null && !s.active) ...[
                  if (!s.canBegin) const Text('请先完成普通同步、冲突处理或已有待处理批次，再开始轮换。'),
                  field('新的独立同步口令', password),
                  field('再次输入新同步口令', repeat),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('我理解其他设备需要使用新凭证接入'),
                    value: understand,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => understand = v!),
                  ),
                  FilledButton(
                    onPressed: busy || !s.canBegin || !understand
                        ? null
                        : () => action(() async {
                            final value = password.text;
                            final repeated = repeat.text;
                            password.clear();
                            repeat.clear();
                            if (value.length < 12) {
                              throw StateError('新同步口令至少需要 12 个字符');
                            }
                            if (value != repeated) {
                              throw StateError('两次输入的同步口令不一致');
                            }
                            final generated = await widget.store.beginRotation(
                              value,
                            );
                            if (mounted) {
                              setState(() {
                                recoveryCode = generated;
                                saved = false;
                              });
                            }
                            return '新密钥已准备，尚未发布。请离线保存并核验新的恢复码。';
                          }),
                    child: const Text('生成新密钥与恢复码'),
                  ),
                ],
                if (s != null && s.active && !s.recoveryConfirmed) ...[
                  const Text(
                    '新恢复码只在生成时展示。关闭后请使用已离线保存的恢复码核验；若未保存，可丢弃未发布的轮换并重新生成。',
                  ),
                  if (recoveryCode.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: SelectableText(recoveryCode),
                    ),
                  field('重新输入新恢复码', code),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('我已离线保存新恢复码'),
                    value: saved,
                    onChanged: busy ? null : (v) => setState(() => saved = v!),
                  ),
                  FilledButton(
                    onPressed: busy || !saved
                        ? null
                        : () => action(() async {
                            final value = code.text;
                            code.clear();
                            await widget.store.confirmRotation(
                              s.batchId,
                              value,
                            );
                            return '新恢复码核验通过，可以发布轮换。';
                          }),
                    child: const Text('核验新恢复码'),
                  ),
                ],
                if (s != null && s.active && s.recoveryConfirmed) ...[
                  const Text('新恢复码已核验。发布并读回确认后才启用新密钥；网络中断时请恢复同一轮换，不会重复生成密钥。'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => action(
                            () => widget.store.publishRotation(s.batchId),
                          ),
                    child: const Text('发布 / 恢复轮换'),
                  ),
                ],
                if (s != null && s.active) ...[
                  const SizedBox(height: 16),
                  if (s.canDiscard) ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('我确认丢弃这次尚未发布的轮换'),
                      value: discard,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => discard = v!),
                    ),
                    OutlinedButton(
                      onPressed: busy || !discard
                          ? null
                          : () => action(() async {
                              await widget.store.discardRotation(s.batchId);
                              code.clear();
                              return '未发布的轮换已丢弃，原密钥和本机数据保留。';
                            }),
                      child: const Text('丢弃未发布轮换'),
                    ),
                  ] else
                    const Text('发布结果尚未解除，不能丢弃或重新生成。请恢复轮换以核对远端结果。'),
                ],
                if (s == null && !busy)
                  OutlinedButton(
                    onPressed: () => action(() async => '状态已刷新'),
                    child: const Text('重新读取轮换状态'),
                  ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(message),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (busy)
            TextButton(
              onPressed: cancelling ? null : cancel,
              child: Text(cancelling ? '正在停止…' : '停止当前操作'),
            ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, message),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
