import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../src/rust/api/proxy.dart';

class ProxyTestDialog extends StatefulWidget {
  final String title;
  final Future<ProxyTestResult> Function(String targetHost, int targetPort) run;
  const ProxyTestDialog({super.key, required this.title, required this.run});
  @override
  State<ProxyTestDialog> createState() => _ProxyTestDialogState();
}

class _ProxyTestDialogState extends State<ProxyTestDialog> {
  final host = TextEditingController();
  final port = TextEditingController();
  bool busy = false;
  String? error;
  ProxyTestResult? result;

  Future<void> start() async {
    final target = host.text.trim();
    final targetPort = int.tryParse(port.text.trim()) ?? 0;
    if (target.isEmpty != (targetPort == 0)) {
      setState(() => error = '目标地址和端口需同时填写，或都留空只测试 TCP');
      return;
    }
    if (target.isNotEmpty && (targetPort < 1 || targetPort > 65535)) {
      setState(() => error = '目标端口必须为 1–65535');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final value = await widget.run(target, targetPort);
      if (mounted) setState(() => result = value);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    host.dispose();
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '只测试网络连通，不发送 SSH 凭证。填写目标后可区分代理认证与目标可达；留空只测试代理 TCP。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: host,
                    enabled: !busy,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '目标主机（可选）',
                      hintText: '例如 internal.example',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: port,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '端口'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : start,
                icon: const Icon(Icons.network_check),
                label: Text(busy ? '测试中…' : '开始测试'),
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (result != null) ...[
              const SizedBox(height: 20),
              _Stage('代理 TCP 可达', result!.tcpOk),
              _Stage('代理认证通过', result!.authenticated),
              _Stage('目标可达（TCP）', result!.targetOk),
              const SizedBox(height: 8),
              SelectableText(
                result!.message,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class ProxyBatchTestDialog extends StatefulWidget {
  final List<ProxyProfile> profiles;
  final Future<ProxyTestResult> Function(
    ProxyProfile profile,
    String targetHost,
    int targetPort,
  )
  run;
  const ProxyBatchTestDialog({
    super.key,
    required this.profiles,
    required this.run,
  });
  @override
  State<ProxyBatchTestDialog> createState() => _ProxyBatchTestDialogState();
}

class _ProxyBatchTestDialogState extends State<ProxyBatchTestDialog> {
  final host = TextEditingController();
  final port = TextEditingController();
  final results = <String, ProxyTestResult>{};
  bool busy = false;
  int completed = 0;
  String? error;

  Future<void> start() async {
    final target = host.text.trim();
    final targetPort = int.tryParse(port.text.trim()) ?? 0;
    if (target.isEmpty != (targetPort == 0)) {
      setState(() => error = '目标地址和端口需同时填写，或都留空只测试 TCP');
      return;
    }
    if (target.isNotEmpty && (targetPort < 1 || targetPort > 65535)) {
      setState(() => error = '目标端口必须为 1–65535');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      results.clear();
      completed = 0;
    });
    try {
      for (final profile in widget.profiles) {
        final value = await widget.run(profile, target, targetPort);
        if (!mounted) return;
        setState(() {
          results[profile.id] = value;
          completed++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    host.dispose();
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('测试全部命名代理'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: host,
                    enabled: !busy,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: '目标主机（可选）'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: port,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '端口'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : start,
                icon: const Icon(Icons.playlist_add_check),
                label: Text(
                  busy ? '测试中 $completed/${widget.profiles.length}…' : '开始测试',
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            for (final profile in widget.profiles) ...[
              const SizedBox(height: 10),
              Text(
                profile.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Builder(
                builder: (context) {
                  final value = results[profile.id];
                  if (value == null) {
                    return const Text(
                      '等待测试',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Stage('TCP', value.tcpOk),
                      _Stage('认证', value.authenticated),
                      _Stage('目标', value.targetOk),
                      Text(value.message, style: const TextStyle(fontSize: 11)),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class _Stage extends StatelessWidget {
  final String label;
  final bool? value;
  const _Stage(this.label, this.value);
  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (value) {
      true => (Icons.check_circle, Colors.green, '通过'),
      false => (Icons.cancel, Theme.of(context).colorScheme.error, '失败'),
      null => (Icons.help_outline, Colors.grey, '未测试'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text('$label：$text', style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
