import '../app/font_catalog.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/ai_assistant.dart';
import '../app/errors.dart';
import '../app/terminal_session.dart';
import '../src/rust/api/client.dart' as native;

class AiSettingsDialog extends StatefulWidget {
  final AiSettings settings;
  const AiSettingsDialog({super.key, required this.settings});
  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  late final base = TextEditingController(text: widget.settings.baseUrl);
  late final model = TextEditingController(text: widget.settings.model);
  late final key = TextEditingController(text: widget.settings.apiKey);
  late final prompt = TextEditingController(text: widget.settings.systemPrompt);
  late final contextLines = TextEditingController(
    text: '${widget.settings.contextLines}',
  );
  late final timeout = TextEditingController(
    text: '${widget.settings.timeoutSeconds}',
  );
  late AiPermission permission = widget.settings.permission;
  List<AiProfile> profiles = [];
  late String activeId = 'default';
  bool profilesReady = false, saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final set = await const AiStore().loadProfiles();
    if (!mounted) return;
    setState(() {
      profiles = set.profiles;
      activeId = set.active?.id ?? profiles.first.id;
      profilesReady = true;
      _apply(set.active?.settings ?? widget.settings);
    });
  }

  void _apply(AiSettings value) {
    base.text = value.baseUrl;
    model.text = value.model;
    key.text = value.apiKey;
    prompt.text = value.systemPrompt;
    contextLines.text = '${value.contextLines}';
    timeout.text = '${value.timeoutSeconds}';
    permission = value.permission;
  }

  AiSettings _current() => AiSettings(
    baseUrl: base.text.trim(),
    model: model.text.trim(),
    apiKey: key.text.trim(),
    systemPrompt: prompt.text.trim().isEmpty
        ? const AiSettings().systemPrompt
        : prompt.text.trim(),
    contextLines: int.tryParse(contextLines.text) ?? 120,
    timeoutSeconds: int.tryParse(timeout.text) ?? 60,
    permission: permission,
  );

  Future<void> _addProfile() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增 AI 环境'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '环境名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    final value = name?.trim() ?? '';
    if (value.isEmpty || !mounted) return;
    final profile = AiProfile(
      id: 'ai-${DateTime.now().microsecondsSinceEpoch}',
      name: value,
      settings: _current(),
    );
    setState(() {
      profiles = [...profiles, profile];
      activeId = profile.id;
    });
  }

  Future<void> _deleteProfile() async {
    if (profiles.length <= 1) return;
    final profile = profiles.where((item) => item.id == activeId).firstOrNull;
    if (profile == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 AI 环境 ${profile.name}？'),
        content: const Text('只删除本机保存的接口配置和 API Key。'),
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
    if (ok != true || !mounted) return;
    final remaining = profiles.where((item) => item.id != activeId).toList();
    setState(() {
      profiles = remaining;
      activeId = remaining.first.id;
      _apply(remaining.first.settings);
    });
  }

  @override
  void dispose() {
    base.dispose();
    model.dispose();
    key.dispose();
    prompt.dispose();
    contextLines.dispose();
    timeout.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final baseUrl = base.text.trim();
    final modelName = model.text.trim();
    final contextCount = int.tryParse(contextLines.text);
    final timeoutSeconds = int.tryParse(timeout.text);
    if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
      setState(() => error = '接口地址必须为 http/https URL');
      return;
    }
    if (modelName.isEmpty ||
        contextCount == null ||
        contextCount < 1 ||
        contextCount > 1000 ||
        timeoutSeconds == null ||
        timeoutSeconds < 5 ||
        timeoutSeconds > 300) {
      setState(() => error = '模型、上下文行数或超时参数无效');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final next = AiSettings(
      baseUrl: baseUrl,
      model: modelName,
      apiKey: key.text.trim(),
      systemPrompt: prompt.text.trim().isEmpty
          ? const AiSettings().systemPrompt
          : prompt.text.trim(),
      contextLines: contextCount,
      timeoutSeconds: timeoutSeconds,
      permission: permission,
    );
    try {
      final updated = [
        for (final profile in profiles)
          profile.id == activeId
              ? AiProfile(id: profile.id, name: profile.name, settings: next)
              : profile,
      ];
      if (updated.isEmpty) {
        updated.add(AiProfile(id: 'default', name: '默认环境', settings: next));
      }
      await const AiStore().saveProfiles(
        AiProfileSet(
          profiles: updated,
          activeId: updated.any((profile) => profile.id == activeId)
              ? activeId
              : updated.first.id,
        ),
      );
      if (mounted) Navigator.pop(context, next);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('AI 助手设置'),
    content: SizedBox(
      width: 560,
      height: 520,
      child: SingleChildScrollView(
        child: Column(
          children: [
            if (profilesReady)
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: activeId,
                      decoration: const InputDecoration(labelText: 'AI 环境'),
                      items: [
                        for (final profile in profiles)
                          DropdownMenuItem(
                            value: profile.id,
                            child: Text(profile.name),
                          ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) {
                              final profile = profiles
                                  .where((item) => item.id == value)
                                  .firstOrNull;
                              if (profile == null) return;
                              setState(() {
                                activeId = profile.id;
                                _apply(profile.settings);
                              });
                            },
                    ),
                  ),
                  IconButton(
                    tooltip: '新增 AI 环境',
                    onPressed: saving ? null : _addProfile,
                    icon: const Icon(Icons.add, size: 18),
                  ),
                  IconButton(
                    tooltip: '删除当前环境',
                    onPressed: saving || profiles.length <= 1
                        ? null
                        : _deleteProfile,
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            TextField(
              controller: base,
              decoration: const InputDecoration(
                labelText: 'OpenAI 兼容接口地址',
                hintText: 'https://api.openai.com/v1',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: model,
              decoration: const InputDecoration(labelText: '模型'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: key,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'API Key',
                helperText: '保存在系统安全存储，本机使用，不进入同步快照',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: contextLines,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '附带最近行数'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: timeout,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '超时（秒）'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AiPermission>(
              initialValue: permission,
              decoration: const InputDecoration(labelText: '命令权限'),
              items: const [
                DropdownMenuItem(value: AiPermission.ask, child: Text('每次询问')),
                DropdownMenuItem(
                  value: AiPermission.readOnly,
                  child: Text('只读命令自动批准'),
                ),
                DropdownMenuItem(
                  value: AiPermission.full,
                  child: Text('完全访问（自动执行）'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => permission = value ?? AiPermission.ask),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: prompt,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '系统提示词',
                alignLabelWithHint: true,
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: saving ? null : save, child: const Text('保存')),
    ],
  );
}

class AiAssistantDialog extends StatefulWidget {
  final TerminalSession session;
  const AiAssistantDialog({super.key, required this.session});
  @override
  State<AiAssistantDialog> createState() => _AiAssistantDialogState();
}

class _AiAssistantDialogState extends State<AiAssistantDialog> {
  final input = TextEditingController();
  final scroll = ScrollController();
  final messages = <_AiMessage>[];
  AiSettings settings = const AiSettings();
  bool loading = true, busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await const AiStore().load();
      if (mounted) setState(() => settings = saved);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  String _context() {
    final lines = widget.session.terminal.buffer.lines;
    final start = (lines.length - settings.contextLines).clamp(0, lines.length);
    final text = StringBuffer();
    for (var i = start; i < lines.length; i++) {
      text.writeln(lines[i].getText());
    }
    final value = text.toString();
    return value.length > 64000 ? value.substring(value.length - 64000) : value;
  }

  Future<void> _settings() async {
    final next = await showDialog<AiSettings>(
      context: context,
      builder: (_) => AiSettingsDialog(settings: settings),
    );
    if (next != null && mounted) setState(() => settings = next);
  }

  Future<void> _send() async {
    final question = input.text.trim();
    if (question.isEmpty || busy) return;
    if (settings.apiKey.trim().isEmpty) {
      await _settings();
      if (settings.apiKey.trim().isEmpty) return;
    }
    final history = messages
        .where((m) => m.role != 'output' && m.text.trim().isNotEmpty)
        .map((m) => (m.role, m.text))
        .toList();
    final bubble = _AiMessage.assistant('', null);
    setState(() {
      busy = true;
      error = null;
      messages
        ..add(_AiMessage.user(question))
        ..add(bubble);
      input.clear();
    });
    _scrollDown();
    try {
      final reply = await AiService(settings: settings, history: history)
          .askStream(
            question: question,
            context: _context(),
            onDelta: (delta) {
              if (!mounted) return;
              setState(() => bubble.text += delta);
              _scrollDown();
            },
            runTool: (command) async {
              if (!await _allowed(command)) return null;
              return native.runCommand(
                connectionId: widget.session.connectionId,
                command: command,
              );
            },
            onToolResult: (command, output) {
              if (!mounted) return;
              setState(
                () => messages.add(
                  _AiMessage.output('\$ $command\n${output.trim()}'),
                ),
              );
              _scrollDown();
            },
          );
      if (!mounted) return;
      setState(() {
        bubble.text = reply.text;
        bubble.command = reply.command;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = userFacingError(e);
          if (bubble.text.trim().isEmpty) messages.remove(bubble);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
      _scrollDown();
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<bool> _allowed(String command) async {
    if (settings.permission == AiPermission.full) return true;
    if (settings.permission == AiPermission.readOnly &&
        isReadOnlyCommand(command)) {
      return true;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('执行 AI 生成的命令？'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请在执行前核对命令。命令将以当前登录用户权限运行。'),
              const SizedBox(height: 12),
              SelectableText(
                command,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: monoFontFallback,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('执行'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _sendToTerminal(_AiMessage message) async {
    final command = message.command;
    if (command == null || !await _allowed(command)) return;
    widget.session.send('$command\n');
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('命令已发送到终端')));
    }
  }

  Future<void> _runSeparately(_AiMessage message) async {
    final command = message.command;
    if (command == null || !await _allowed(command)) return;
    setState(() => busy = true);
    try {
      final output = await native.runCommand(
        connectionId: widget.session.connectionId,
        command: command,
      );
      if (!mounted) return;
      setState(
        () => messages.add(
          _AiMessage.output(output.trim().isEmpty ? '（无输出）' : output),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
      _scrollDown();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const AlertDialog(
        content: SizedBox(
          height: 160,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 18),
          const SizedBox(width: 8),
          const Expanded(child: Text('终端 AI 助手')),
          IconButton(
            tooltip: 'AI 设置',
            onPressed: busy ? null : _settings,
            icon: const Icon(Icons.settings_outlined, size: 18),
          ),
          IconButton(
            tooltip: '清空对话',
            onPressed: busy || messages.isEmpty
                ? null
                : () => setState(messages.clear),
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
          ),
        ],
      ),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                controller: scroll,
                children: [
                  for (final message in messages) ...[
                    Align(
                      alignment: message.role == 'user'
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        constraints: const BoxConstraints(maxWidth: 620),
                        decoration: BoxDecoration(
                          color: message.role == 'user'
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SelectableText(
                          message.text,
                          style: TextStyle(
                            fontFamily: message.role == 'output'
                                ? 'monospace'
                                : null,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    if (message.command != null)
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                message.command!,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontFamilyFallback: monoFontFallback,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => _sendToTerminal(message),
                                    icon: const Icon(Icons.terminal, size: 16),
                                    label: const Text('发送到终端'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => _runSeparately(message),
                                    icon: const Icon(
                                      Icons.play_arrow,
                                      size: 16,
                                    ),
                                    label: const Text('独立执行'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => Clipboard.setData(
                                      ClipboardData(text: message.command!),
                                    ),
                                    icon: const Icon(Icons.copy, size: 16),
                                    label: const Text('复制'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
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
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    enabled: !busy,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: '询问当前终端，例如：哪个进程占用 CPU 最高？',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: busy ? null : _send,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _AiMessage {
  final String role;
  String text;
  String? command;
  _AiMessage(this.role, this.text, [this.command]);
  factory _AiMessage.user(String text) => _AiMessage('user', text);
  factory _AiMessage.assistant(String text, String? command) =>
      _AiMessage('assistant', text, command);
  factory _AiMessage.output(String text) => _AiMessage('output', text);
}
