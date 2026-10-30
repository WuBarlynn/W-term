import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/forward_store.dart';
import '../src/rust/api/forward.dart';

const _loopback = {'127.0.0.1', '::1', 'localhost'};

String kindLabel(String kind) => switch (kind) {
  'remote' => '远程 -R',
  'dynamic' => '动态 SOCKS5 -D',
  _ => '本地 -L',
};

class ForwardingDialog extends StatefulWidget {
  final ForwardingStore store;
  final String? hostId;
  final String hostName;
  const ForwardingDialog({
    super.key,
    required this.store,
    this.hostId,
    this.hostName = '',
  });
  @override
  State<ForwardingDialog> createState() => _ForwardingDialogState();
}

class _ForwardingDialogState extends State<ForwardingDialog> {
  final form = GlobalKey<FormState>();
  final listenHost = TextEditingController(text: '127.0.0.1');
  final listenPort = TextEditingController(text: '0');
  final targetHost = TextEditingController(text: '127.0.0.1');
  final targetPort = TextEditingController();
  final ruleName = TextEditingController();
  final search = TextEditingController();
  String kind = 'local';
  String editingRuleId = '';
  bool allowExternal = false;
  List<ForwardInfo> active = [];
  List<ForwardRule> rules = [];
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
    reloadRules();
  }

  @override
  void dispose() {
    for (final controller in [
      listenHost,
      listenPort,
      targetHost,
      targetPort,
      ruleName,
      search,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get loopback => _loopback.contains(listenHost.text.trim().toLowerCase());
  bool get externalAllowed => loopback || allowExternal;

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      final result = await widget.store.listForwards();
      if (mounted) setState(() => active = result);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() => perform(() async {});

  Future<void> reloadRules() async {
    if (widget.hostId == null) return;
    try {
      final result = await widget.store.forwardRules();
      if (mounted) setState(() => rules = result);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  String? portError(String? input, bool allowZero) {
    final value = int.tryParse(input ?? '');
    return value == null || value < (allowZero ? 0 : 1) || value > 65535
        ? '端口范围 ${allowZero ? 0 : 1}–65535'
        : null;
  }

  String? hostError(String? input) =>
      input == null ||
          input.trim().isEmpty ||
          input.trim().length > 253 ||
          RegExp(r'\s').hasMatch(input.trim())
      ? '请输入有效地址'
      : null;

  Future<void> start() async {
    if (!form.currentState!.validate()) return;
    if (!externalAllowed) {
      setState(() => error = '请先确认外部访问风险');
      return;
    }
    await perform(() async {
      final entry = await widget.store.startForward(
        kind: kind,
        listenHost: listenHost.text.trim(),
        listenPort: int.parse(listenPort.text),
        targetHost: kind == 'dynamic' ? '' : targetHost.text.trim(),
        targetPort: kind == 'dynamic' ? 0 : int.parse(targetPort.text),
      );
      if (mounted) setState(() => active = [...active, entry]);
    });
  }

  Future<void> saveRule() async {
    if (widget.hostId == null || busy) return;
    if (!form.currentState!.validate()) return;
    if (!externalAllowed) {
      setState(() => error = '请先确认外部访问风险');
      return;
    }
    if (ruleName.text.trim().isEmpty) {
      setState(() => error = '请填写规则名称');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final saved = await widget.store.saveForwardRule(
        ForwardRule(
          id: editingRuleId,
          hostId: widget.hostId!,
          name: ruleName.text.trim(),
          kind: kind,
          listenHost: listenHost.text.trim(),
          listenPort: int.parse(listenPort.text),
          targetHost: kind == 'dynamic' ? '' : targetHost.text.trim(),
          targetPort: kind == 'dynamic' ? 0 : int.parse(targetPort.text),
        ),
      );
      if (mounted) {
        setState(() {
          editingRuleId = saved.id;
          ruleName.text = saved.name;
        });
      }
      await reloadRules();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> startRule(ForwardRule rule) async {
    if (!_loopback.contains(rule.listenHost.trim().toLowerCase())) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('允许外部访问监听？'),
          content: Text(
            '规则“${rule.name}”监听 ${rule.listenHost}:${rule.listenPort}，'
            '不是回环地址，可能被局域网或公网访问。确认启动？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认启动'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    await perform(() async {
      final entry = await widget.store.startForward(
        kind: rule.kind,
        listenHost: rule.listenHost,
        listenPort: rule.listenPort,
        targetHost: rule.targetHost,
        targetPort: rule.targetPort,
      );
      if (mounted) setState(() => active = [...active, entry]);
    });
  }

  Future<void> stopRule(ForwardRule rule) async {
    final entry = activeFor(rule);
    if (entry == null) return;
    await perform(() => widget.store.stopForward(entry.id));
  }

  Future<void> deleteRule(ForwardRule rule) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除规则“${rule.name}”？'),
        content: const Text('仅删除保存的规则；正在运行的转发需要单独停止。'),
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
      await widget.store.deleteForwardRule(rule.id);
      if (editingRuleId == rule.id) resetForm();
      await reloadRules();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void editRule(ForwardRule rule) {
    setState(() {
      editingRuleId = rule.id;
      ruleName.text = rule.name;
      kind = rule.kind;
      listenHost.text = rule.listenHost;
      listenPort.text = '${rule.listenPort}';
      targetHost.text = rule.targetHost;
      targetPort.text = rule.targetPort == 0 ? '' : '${rule.targetPort}';
      error = null;
    });
  }

  void resetForm() {
    editingRuleId = '';
    ruleName.clear();
    listenHost.text = '127.0.0.1';
    listenPort.text = '0';
    targetHost.text = '127.0.0.1';
    targetPort.clear();
    kind = 'local';
    allowExternal = false;
  }

  ForwardInfo? activeFor(ForwardRule rule) {
    for (final entry in active) {
      if (entry.kind != rule.kind || entry.listenHost != rule.listenHost) {
        continue;
      }
      if (rule.listenPort != 0 && entry.listenPort != rule.listenPort) {
        continue;
      }
      if (rule.kind != 'dynamic' &&
          (entry.targetHost != rule.targetHost ||
              entry.targetPort != rule.targetPort)) {
        continue;
      }
      return entry;
    }
    return null;
  }

  String location(ForwardInfo info) => info.listenRemote
      ? '远端 ${info.listenHost}:${info.listenPort}'
      : '本机 ${info.listenHost}:${info.listenPort}';

  String ruleTarget(ForwardRule rule) => rule.kind == 'dynamic'
      ? 'SOCKS5（客户端自选目标）'
      : '→ ${rule.targetHost}:${rule.targetPort}';

  List<ForwardRule> get visibleRules {
    final query = search.text.trim().toLowerCase();
    if (query.isEmpty) return rules;
    return rules.where((rule) {
      final text =
          '${rule.name} ${rule.kind} ${rule.listenHost}:${rule.listenPort} '
                  '${rule.targetHost}:${rule.targetPort}'
              .toLowerCase();
      return text.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('端口转发'),
      scrollable: true,
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '会话级转发，断开会话会停止全部监听。规则只保存在本机，不进入同步；保存规则不会自动启动。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'local', label: Text('本地 -L')),
                ButtonSegment(value: 'remote', label: Text('远程 -R')),
                ButtonSegment(value: 'dynamic', label: Text('动态 -D')),
              ],
              selected: {kind},
              onSelectionChanged: busy
                  ? null
                  : (value) => setState(() => kind = value.first),
            ),
            const SizedBox(height: 8),
            Text(switch (kind) {
              'remote' =>
                '监听建立在 SSH 服务器上，目标由本机连接。默认 127.0.0.1 仅服务器本机可访问；服务器可能限制其他监听地址。',
              'dynamic' =>
                '在本机启动 SOCKS5 代理，客户端自选目标，经当前 SSH 连接转发。仅 TCP，不包含 UDP/VPN。',
              _ => '监听建立在本机，目标由 SSH 服务器连接。默认 127.0.0.1 仅本机可访问。',
            }, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            Form(
              key: form,
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: listenHost,
                          enabled: !busy,
                          autocorrect: false,
                          onChanged: (_) => setState(() {
                            allowExternal = false;
                          }),
                          decoration: InputDecoration(
                            labelText: kind == 'remote' ? '远端监听地址' : '本地监听地址',
                          ),
                          validator: hostError,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 150,
                        child: TextFormField(
                          controller: listenPort,
                          enabled: !busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '监听端口（0 自动）',
                          ),
                          validator: (v) => portError(v, true),
                        ),
                      ),
                    ],
                  ),
                  if (kind != 'dynamic') ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: targetHost,
                            enabled: !busy,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: kind == 'remote'
                                  ? '本机目标主机'
                                  : '目标主机（服务器侧）',
                            ),
                            validator: hostError,
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 150,
                          child: TextFormField(
                            controller: targetPort,
                            enabled: !busy,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '目标端口',
                            ),
                            validator: (v) => portError(v, false),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (widget.hostId != null) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: ruleName,
                      enabled: !busy,
                      decoration: InputDecoration(
                        labelText: editingRuleId.isEmpty ? '规则名称' : '编辑规则名称',
                        helperText: '保存后可在本机规则中手动启动；不会自动监听。',
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!loopback) ...[
              const SizedBox(height: 8),
              Text(
                kind == 'dynamic'
                    ? '监听地址不是回环：任何能访问该地址的设备都可以使用这个 SOCKS5 代理。'
                    : '监听地址不是回环：局域网或公网设备可能访问此转发，请确认服务器和网络边界。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: allowExternal,
                onChanged: busy
                    ? null
                    : (value) => setState(() => allowExternal = value ?? false),
                title: Text(
                  kind == 'dynamic'
                      ? '我确认允许其他设备使用此 SOCKS5 代理'
                      : '我确认允许外部访问此监听地址',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: busy || !externalAllowed ? null : start,
                  child: const Text('启动转发'),
                ),
                if (widget.hostId != null)
                  OutlinedButton(
                    onPressed: busy || !externalAllowed ? null : saveRule,
                    child: Text(editingRuleId.isEmpty ? '保存规则' : '更新规则'),
                  ),
                if (editingRuleId.isNotEmpty)
                  TextButton(
                    onPressed: busy ? null : () => setState(resetForm),
                    child: const Text('取消编辑'),
                  ),
              ],
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            if (error != null)
              SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const Divider(height: 28),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '当前会话转发',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : refresh,
                  child: const Text('刷新'),
                ),
              ],
            ),
            if (active.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无转发'),
              ),
            for (final entry in active)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${kindLabel(entry.kind)} · ${location(entry)}',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  entry.kind == 'dynamic'
                      ? 'SOCKS5 入口，目标由客户端选择'
                      : '→ ${entry.targetHost}:${entry.targetPort}'
                            '${entry.lastError == null ? '' : '\n${userFacingError(entry.lastError!)}'}',
                ),
                trailing: IconButton(
                  tooltip: '停止转发 ${entry.listenPort}',
                  onPressed: busy
                      ? null
                      : () => perform(() async {
                          await widget.store.stopForward(entry.id);
                          if (mounted) {
                            setState(
                              () => active = active
                                  .where((item) => item.id != entry.id)
                                  .toList(),
                            );
                          }
                        }),
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              ),
            const Divider(height: 28),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '保存的规则',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.hostName.isNotEmpty)
                  Text(
                    widget.hostName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                if (widget.hostId == null)
                  const Text(
                    '临时连接不保存规则',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
            if (widget.hostId != null) ...[
              const SizedBox(height: 4),
              TextField(
                controller: search,
                enabled: !busy,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '搜索规则（名称/地址/端口）',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
              ),
              if (rules.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('暂无保存的规则'),
                ),
              for (final rule in visibleRules)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(rule.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${kindLabel(rule.kind)} · ${rule.listenHost}:${rule.listenPort}'
                    ' ${ruleTarget(rule)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  leading: Icon(
                    activeFor(rule) == null
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    size: 20,
                    color: activeFor(rule) == null
                        ? null
                        : Theme.of(context).colorScheme.primary,
                  ),
                  onTap: busy ? null : () => editRule(rule),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (activeFor(rule) == null)
                        IconButton(
                          tooltip: '启动规则 ${rule.name}',
                          onPressed: busy ? null : () => startRule(rule),
                          icon: const Icon(Icons.play_arrow, size: 20),
                        )
                      else
                        IconButton(
                          tooltip: '停止规则 ${rule.name}',
                          onPressed: busy ? null : () => stopRule(rule),
                          icon: const Icon(
                            Icons.stop_circle_outlined,
                            size: 20,
                          ),
                        ),
                      PopupMenuButton<String>(
                        enabled: !busy,
                        tooltip: '规则操作：${rule.name}',
                        onSelected: (value) {
                          if (value == 'edit') {
                            editRule(rule);
                          } else {
                            deleteRule(rule);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
