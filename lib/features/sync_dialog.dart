import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/sync_store.dart';
import 'sync_conflicts_dialog.dart';
import 'sync_rotation_dialog.dart';
import 'sync_scope_dialog.dart';

class SyncDialog extends StatefulWidget {
  final SyncStore store;
  const SyncDialog({super.key, required this.store});
  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  final owner = TextEditingController();
  final repository = TextEditingController();
  final branch = TextEditingController(text: 'main');
  final token = TextEditingController();
  final secret = TextEditingController();
  final recovery = TextEditingController();
  final adoptionSecret = TextEditingController();
  String adoptionMode = 'password';
  bool adoptionConfirmed = false;
  SyncProfile? profile;
  String mode = 'create', message = '', recoveryCode = '';
  bool settingsDirty = false;
  bool busy = true, consent = false, savedRecovery = false, cancelling = false;

  @override
  void initState() {
    super.initState();
    loadInitial();
  }

  Future<void> refresh({bool fields = false}) async {
    final value = await widget.store.syncSettings();
    if (!mounted) return;
    setState(() {
      profile = value;
      if (fields) {
        owner.text = value.owner;
        repository.text = value.repository;
        branch.text = value.branch;
      }
    });
  }

  Future<void> loadInitial() async {
    try {
      await refresh(fields: true);
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(Future<String> Function() work) async {
    setState(() {
      busy = true;
      cancelling = false;
      message = '';
    });
    try {
      final result = await work();
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) setState(() => message = userFacingError(e));
    } finally {
      // Refresh even after a failed upload: the native outbox may now be pending.
      try {
        await refresh();
      } catch (_) {
        /* Keep the operation error visible. */
      }
      if (mounted) {
        setState(() {
          busy = false;
          cancelling = false;
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
    for (final c in [
      owner,
      repository,
      branch,
      token,
      secret,
      recovery,
      adoptionSecret,
    ]) {
      c.clear();
      c.dispose();
    }
    recoveryCode = '';
    super.dispose();
  }

  Widget field(
    String label,
    TextEditingController controller, {
    bool sensitive = false,
    bool enabled = true,
    String? helper,
    bool setting = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      onChanged: setting ? (_) => setState(() => settingsDirty = true) : null,
      enabled: !busy && enabled,
      obscureText: sensitive,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: sensitive
          ? TextInputType.visiblePassword
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: const Text('GitHub 加密同步'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '使用已有的 GitHub 私有仓库和分支。请先在 GitHub 创建仓库并添加 README，再填写拥有该仓库 Contents 读写权限的令牌。',
                ),
                const SizedBox(height: 18),
                if (p != null) ...[
                  field('仓库所有者', owner, enabled: !p.initialized, setting: true),
                  field(
                    '仓库名称',
                    repository,
                    enabled: !p.initialized,
                    setting: true,
                  ),
                  field(
                    '分支',
                    branch,
                    enabled: !p.initialized,
                    setting: true,
                    helper: '填写 GitHub 上已有的分支，区分大小写，例如 main 或 master。',
                  ),
                  field(
                    'GitHub 令牌',
                    token,
                    setting: true,
                    sensitive: true,
                    helper: p.tokenSaved
                        ? '已加密保存在本机；留空保留现有令牌。请确认令牌授权了此仓库，且 Contents 为 Read and write。'
                        : '令牌加密保存在本机保险库。Fine-grained token 需选对 Resource owner、授权此仓库，并启用 Contents: Read and write。',
                  ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => action(() async {
                            final value = token.text;
                            token.clear();
                            await widget.store.saveSyncSettings(
                              owner.text,
                              repository.text,
                              branch.text,
                              value,
                            );
                            if (mounted) setState(() => settingsDirty = false);
                            return '仓库设置已保存';
                          }),
                    child: const Text('保存仓库设置'),
                  ),
                  const SizedBox(height: 18),
                  if (p.configured) ...[
                    OutlinedButton.icon(
                      onPressed: busy || settingsDirty
                          ? null
                          : () => action(widget.store.checkSync),
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('检查仓库与分支'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (p.configured && !p.recoveryConfirmed) ...[
                    if (!p.initialized) ...[
                      DropdownButtonFormField<String>(
                        initialValue: mode,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '同步空间'),
                        items: const [
                          DropdownMenuItem(
                            value: 'create',
                            child: Text('创建同步空间'),
                          ),
                          DropdownMenuItem(
                            value: 'password',
                            child: Text('使用同步口令接入'),
                          ),
                          DropdownMenuItem(
                            value: 'recovery',
                            child: Text('使用恢复码接入'),
                          ),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setState(() {
                                mode = v!;
                                secret.clear();
                              }),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (!p.initialized || recoveryCode.isEmpty) ...[
                      field(
                        mode == 'recovery' && !p.initialized
                            ? '同步恢复码'
                            : '独立同步口令',
                        secret,
                        sensitive: true,
                        helper: mode == 'create' || p.initialized
                            ? '至少 12 个字符；所有设备使用同一同步口令。'
                            : null,
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许加密同步主机、文件夹、身份和命令片段'),
                        subtitle: const Text(
                          '包括已保存的密码和可导出私钥；服务器指纹与 GitHub 令牌不参与同步。',
                        ),
                        value: consent,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => consent = v!),
                      ),
                      FilledButton(
                        onPressed: busy || settingsDirty || !consent
                            ? null
                            : () => action(() async {
                                final value = secret.text;
                                secret.clear();
                                final code = await widget.store.initializeSync(
                                  p.initialized ? 'create' : mode,
                                  value,
                                );
                                if (mounted) {
                                  setState(() {
                                    recoveryCode = code;
                                    savedRecovery = false;
                                    recovery.clear();
                                  });
                                }
                                return code.isEmpty
                                    ? '已接入同步空间。点击立即同步以合并数据。'
                                    : '请离线保存恢复码，并在下方重新输入核验。';
                              }),
                        child: Text(
                          p.initialized
                              ? '重新生成恢复码'
                              : mode == 'create'
                              ? '创建同步空间'
                              : '接入同步空间',
                        ),
                      ),
                    ],
                    if (p.initialized) ...[
                      const SizedBox(height: 18),
                      const Text('恢复码用于找回同步密钥，请离线保管。核验前不会上传数据。'),
                      if (recoveryCode.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: SelectableText(recoveryCode),
                        ),
                      field('重新输入恢复码', recovery, sensitive: true),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('我已离线保存恢复码'),
                        value: savedRecovery,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => savedRecovery = v!),
                      ),
                      FilledButton(
                        onPressed: busy || settingsDirty || !savedRecovery
                            ? null
                            : () => action(() async {
                                final value = recovery.text;
                                recovery.clear();
                                await widget.store.confirmSyncRecovery(value);
                                if (mounted) setState(() => recoveryCode = '');
                                return '恢复码核验通过，可以开始同步';
                              }),
                        child: const Text('核验恢复码'),
                      ),
                    ],
                  ],
                  if (p.initialized)
                    OutlinedButton(
                      onPressed: busy || settingsDirty
                          ? null
                          : () async {
                              final saved = await showDialog<bool>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) =>
                                    SyncScopeDialog(store: widget.store),
                              );
                              if (!mounted) return;
                              if (saved == true) {
                                setState(
                                  () => message = '仅本机范围已保存；后续普通同步将应用这些规则',
                                );
                              }
                            },
                      child: const Text('管理仅本机范围'),
                    ),
                  if (p.recoveryConfirmed) ...[
                    OutlinedButton(
                      onPressed: busy || settingsDirty
                          ? null
                          : () async {
                              final result = await showDialog<String>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) =>
                                    SyncRotationDialog(store: widget.store),
                              );
                              if (!mounted) return;
                              if (result != null) {
                                setState(() => message = result);
                              }
                              try {
                                await refresh();
                              } catch (e) {
                                if (mounted) {
                                  setState(() => message = userFacingError(e));
                                }
                              }
                            },
                      child: const Text('轮换 / 恢复同步密钥'),
                    ),
                    ExpansionTile(
                      title: const Text('接入新同步密钥'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 18),
                      children: [
                        const Text(
                          '另一台设备轮换密钥后，输入新的同步口令或恢复码。验证成功只更新本机同步密钥；点击立即同步后再合并数据。',
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey('adoption-$adoptionMode'),
                          initialValue: adoptionMode,
                          decoration: const InputDecoration(
                            labelText: '新密钥验证方式',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'password',
                              child: Text('新同步口令'),
                            ),
                            DropdownMenuItem(
                              value: 'recovery',
                              child: Text('新恢复码'),
                            ),
                          ],
                          onChanged: busy || p.pending
                              ? null
                              : (value) {
                                  setState(() {
                                    adoptionMode = value!;
                                    adoptionSecret.clear();
                                    adoptionConfirmed = false;
                                  });
                                },
                        ),
                        const SizedBox(height: 14),
                        field(
                          adoptionMode == 'password' ? '输入新同步口令' : '输入新恢复码',
                          adoptionSecret,
                          sensitive: true,
                          enabled: !p.pending,
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('确认接入另一台设备轮换后的密钥'),
                          value: adoptionConfirmed,
                          onChanged: busy || p.pending
                              ? null
                              : (value) =>
                                    setState(() => adoptionConfirmed = value!),
                        ),
                        if (p.pending) const Text('请先恢复待处理同步；不会丢弃发布结果未知的批次。'),
                        OutlinedButton(
                          onPressed:
                              busy ||
                                  settingsDirty ||
                                  p.pending ||
                                  !adoptionConfirmed
                              ? null
                              : () => action(() async {
                                  final value = adoptionSecret.text;
                                  adoptionSecret.clear();
                                  if (value.isEmpty) {
                                    throw StateError('请输入新同步口令或恢复码');
                                  }
                                  final result = await widget.store
                                      .adoptSyncKey(adoptionMode, value);
                                  if (mounted) {
                                    setState(() => adoptionConfirmed = false);
                                  }
                                  return result;
                                }),
                          child: const Text('验证并接入新密钥'),
                        ),
                      ],
                    ),
                    OutlinedButton(
                      onPressed: busy || settingsDirty || p.pending
                          ? null
                          : () async {
                              final result = await showDialog<String>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) =>
                                    SyncConflictsDialog(store: widget.store),
                              );
                              if (!mounted) return;
                              if (result != null) {
                                setState(() => message = result);
                              }
                              try {
                                await refresh();
                              } catch (e) {
                                if (mounted) {
                                  setState(() => message = userFacingError(e));
                                }
                              }
                            },
                      child: const Text('处理同步冲突'),
                    ),

                    Text(
                      p.pending
                          ? '有待处理的同步，将先核对发布结果。若远端已更新且旧批次确认未发布，会保留本机修改并重新合并。'
                          : '同步空间已就绪。首次接入会合并本机与远端数据。',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: busy || settingsDirty
                          ? null
                          : () => action(widget.store.runSync),
                      icon: const Icon(Icons.sync),
                      label: Text(p.pending ? '恢复待处理同步' : '立即同步'),
                    ),
                  ],
                ],
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (settingsDirty)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('设置有改动，请先保存仓库设置。'),
                  ),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(message, key: const ValueKey('sync-message')),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (busy && profile != null)
            TextButton(
              onPressed: cancelling ? null : cancel,
              child: Text(cancelling ? '正在取消…' : '取消操作'),
            ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
