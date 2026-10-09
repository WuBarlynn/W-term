import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/sync_store.dart';

class SyncDisconnectDialog extends StatefulWidget {
  final SyncStore store;
  const SyncDisconnectDialog({super.key, required this.store});
  @override
  State<SyncDisconnectDialog> createState() => _SyncDisconnectDialogState();
}

class _SyncDisconnectDialogState extends State<SyncDisconnectDialog> {
  SyncDisconnectInfo? info;
  final confirmation = TextEditingController();
  bool busy = true, acknowledged = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    confirmation.clear();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = '';
      acknowledged = false;
      confirmation.clear();
    });
    try {
      final v = await widget.store.disconnectPreview();
      if (mounted) setState(() => info = v);
    } catch (e) {
      if (mounted) {
        setState(() {
          info = null;
          error = userFacingError(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> disconnect() async {
    final v = info!;
    final text = confirmation.text;
    confirmation.clear();
    setState(() => busy = true);
    try {
      await widget.store.disconnectSync(v.revision, text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          info = null;
          acknowledged = false;
          error = userFacingError(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = info;
    final allowed = v != null && v.blockedReason.isEmpty && !busy;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.all(16),
        title: const Text('断开同步仓库'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (v != null) Text(v.target),
              const SizedBox(height: 16),
              const Text(
                '保留本机主机、身份、片段和仅本机规则。移除本机仓库设置、GitHub 令牌、同步检查点及同步密钥历史；旧仓库、其他设备和 GitHub 上的令牌授权不变。',
              ),
              const SizedBox(height: 12),
              const Text(
                '如需恢复旧空间，请先保存同步口令或恢复码。需要读取旧密钥对应的历史数据时，还需保留断开前的加密备份；当前恢复码不能恢复全部旧密钥，现有备份恢复界面也不会自动恢复同步密钥历史。',
              ),
              const SizedBox(height: 12),
              const Text('断开后可填写新仓库，再创建或接入同步空间；随后手动同步会合并本机现有数据。'),
              if (v != null && v.blockedReason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(v.blockedReason),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('我已保存所需恢复凭证和备份，理解本机旧同步密钥将移除'),
                value: acknowledged,
                onChanged: allowed
                    ? (b) => setState(() => acknowledged = b!)
                    : null,
              ),
              TextField(
                controller: confirmation,
                enabled: allowed,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: '输入“断开”确认'),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(error),
                ),
              if (v == null && !busy)
                TextButton(onPressed: load, child: const Text('重新检查断开信息')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: allowed && acknowledged && confirmation.text == '断开'
                ? disconnect
                : null,
            child: const Text('确认断开'),
          ),
        ],
      ),
    );
  }
}
