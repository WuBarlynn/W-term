import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../src/rust/api/forward.dart';

class ForwardingDialog extends StatefulWidget {
  final Future<List<LocalForward>> Function() onList;
  final Future<LocalForward> Function(int, String, int) onStart;
  final Future<void> Function(String) onStop;
  const ForwardingDialog({
    super.key,
    required this.onList,
    required this.onStart,
    required this.onStop,
  });
  @override
  State<ForwardingDialog> createState() => _ForwardingDialogState();
}

class _ForwardingDialogState extends State<ForwardingDialog> {
  final local = TextEditingController(text: '0');
  final host = TextEditingController(text: '127.0.0.1');
  final port = TextEditingController();
  final form = GlobalKey<FormState>();
  List<LocalForward> entries = [];
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    local.dispose();
    host.dispose();
    port.dispose();
    super.dispose();
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      final result = await widget.onList();
      if (mounted) setState(() => entries = result);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() => perform(() async {});
  Future<void> start() async {
    if (!form.currentState!.validate()) return;
    await perform(() async {
      await widget
          .onStart(
            int.parse(local.text),
            host.text.trim(),
            int.parse(port.text),
          )
          .then((entry) {
            // Keep the confirmed operation visible even if the next refresh fails.
            if (mounted) setState(() => entries = [...entries, entry]);
          });
    });
  }

  String? portError(String? input, bool allowZero) {
    final value = int.tryParse(input ?? '');
    return value == null || value < (allowZero ? 0 : 1) || value > 65535
        ? '端口范围 ${allowZero ? 0 : 1}–65535'
        : null;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('本地端口转发'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '仅监听本机 127.0.0.1。目标地址由 SSH 服务器连接。断开会话会停止全部转发，不自动恢复。',
              style: TextStyle(fontSize: 12),
            ),
            Form(
              key: form,
              child: Column(
                children: [
                  TextFormField(
                    controller: host,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: '目标主机'),
                    autocorrect: false,
                    validator: (v) =>
                        v == null ||
                            v.trim().isEmpty ||
                            v.trim().length > 253 ||
                            RegExp(r'\s').hasMatch(v.trim())
                        ? '请输入有效目标主机'
                        : null,
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: local,
                          enabled: !busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '本地端口（0 自动）',
                          ),
                          validator: (v) => portError(v, true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: port,
                          enabled: !busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '目标端口'),
                          validator: (v) => portError(v, false),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : start,
              child: const Text('启动转发'),
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const Divider(),
            const Text(
              '监听成功不代表目标可达；使用本地端口后刷新可查看连接错误。',
              style: TextStyle(fontSize: 12),
            ),
            if (entries.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('暂无转发')),
            for (final entry in entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: SelectableText('127.0.0.1:${entry.localPort}'),
                subtitle: Text(
                  '→ ${entry.targetHost}:${entry.targetPort}${entry.lastError == null ? '' : '\n${userFacingError(entry.lastError!)}'}',
                ),
                trailing: IconButton(
                  tooltip: '停止转发 ${entry.localPort}',
                  onPressed: busy
                      ? null
                      : () => perform(() async {
                          await widget.onStop(entry.id);
                          if (mounted) {
                            setState(
                              () => entries = entries
                                  .where((item) => item.id != entry.id)
                                  .toList(),
                            );
                          }
                        }),
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : refresh, child: const Text('刷新')),
        FilledButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
