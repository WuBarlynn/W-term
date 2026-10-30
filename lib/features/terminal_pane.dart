import '../app/snippet_store.dart';
import '../app/command_completion.dart';
import '../app/keyword_highlights.dart';
import 'keyword_highlight_dialog.dart';
import 'snippets_dialog.dart';
import 'terminal_search.dart';
import '../app/terminal_appearance.dart';
import 'terminal_appearance_dialog.dart';
import 'system_monitor_dialog.dart';
import 'tmux_dialog.dart';
import 'ai_assistant_dialog.dart';
import 'plugin_settings_dialog.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/rendering.dart';
import 'package:xterm/xterm.dart';

import '../app/terminal_session.dart';
import '../app/pinned_commands.dart';
import '../app/plugins.dart';
import '../src/rust/api/client.dart' as native;
import '../app/errors.dart';
import '../app/workspace_layout.dart';

/// A view over a [TerminalSession]. Multiple panes never own the SSH session;
/// disposing or moving this widget never disconnects the connection.
class TerminalPane extends StatefulWidget {
  final TerminalSession session;
  final SnippetStore? snippets;
  final bool active;
  final BroadcastScope broadcastScope;
  final List<TerminalSession> broadcastTargets;
  final ValueChanged<BroadcastScope>? onBroadcastChanged;
  final void Function(String action, int? index)? onShortcut;
  final VoidCallback? onReconnect;
  final VoidCallback? onOpenFiles;
  final VoidCallback onActivate;
  final VoidCallback? onSplitHorizontal;
  final VoidCallback? onSplitVertical;
  final VoidCallback? onSplitBack;
  final VoidCallback? onClosePane;
  const TerminalPane({
    super.key,
    required this.session,
    this.snippets,
    required this.active,
    this.broadcastScope = BroadcastScope.off,
    this.broadcastTargets = const [],
    this.onBroadcastChanged,
    this.onShortcut,
    this.onReconnect,
    this.onOpenFiles,
    required this.onActivate,
    this.onSplitHorizontal,
    this.onSplitVertical,
    this.onSplitBack,
    this.onClosePane,
  });
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final controller = TerminalController();
  final focus = FocusNode();
  final _terminalBoundary = GlobalKey();
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  bool _wasActive = false;
  Timer? _copyTimer;
  String? _autoCopied;
  final _inputTracker = TerminalInputTracker();
  Timer? _highlightTimer;
  List<CommandCompletion> _completions = const [];
  String _completionSignature = '';
  @override
  void initState() {
    super.initState();
    terminalAppearance.addListener(appearanceChanged);
    widget.session.addListener(sessionChanged);
    pinnedCommands.addListener(sessionChanged);
    controller.addListener(_selectionForCopy);
    pluginSettings.addListener(_pluginSettingsChanged);
    keywordHighlights.addListener(_highlightSettingsChanged);
    widget.session.terminal.onOutput = _output;
    _wasActive = widget.active;
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focus();
        _applyHighlights();
      });
    }
  }

  @override
  void didUpdateWidget(covariant TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(sessionChanged);
      oldWidget.session.terminal.onOutput = oldWidget.session.send;
      widget.session.addListener(sessionChanged);
      widget.session.terminal.onOutput = _output;
    }
    if (widget.active && !_wasActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus());
    }
    _wasActive = widget.active;
  }

  /// Routes terminal input through the pane so an explicit broadcast scope
  /// writes the same bytes to every connected target.
  void _output(String text) {
    widget.session.send(text);
    for (final target in widget.broadcastTargets) {
      target.send(text, record: false);
    }
    _inputTracker.feed(text);
    _refreshCompletions();
    _scheduleHighlights();
  }

  void _refreshCompletions() {
    if (!mounted) return;
    final next = pluginSettings.commandCompletion && !ended
        ? commandSuggestions(_inputTracker.current)
        : <CommandCompletion>[];
    final signature = next
        .map((entry) => '${entry.group}\u0000${entry.value}')
        .join('\u0001');
    if (signature == _completionSignature) return;
    setState(() {
      _completions = next;
      _completionSignature = signature;
    });
  }

  void _pluginSettingsChanged() {
    if (!pluginSettings.commandCompletion) _refreshCompletions();
  }

  void _highlightSettingsChanged() {
    _applyHighlights();
  }

  void _scheduleHighlights() {
    _highlightTimer?.cancel();
    _highlightTimer = Timer(
      const Duration(milliseconds: 500),
      _applyHighlights,
    );
  }

  void _applyHighlights() {
    try {
      for (final highlight in List.of(controller.highlights)) {
        highlight.dispose();
      }
      if (!keywordHighlights.enabled || keywordHighlights.keywords.isEmpty) {
        return;
      }
      final lines = widget.session.terminal.buffer.lines;
      final start = (lines.length - 3000).clamp(0, lines.length);
      final texts = [
        for (var index = start; index < lines.length; index++)
          lines[index].getText(),
      ];
      final matches = findKeywordMatches(texts, keywordHighlights.keywords);
      for (final match in matches) {
        final first = widget.session.terminal.buffer.createAnchor(
          match.start,
          match.line + start,
        );
        final last = widget.session.terminal.buffer.createAnchor(
          match.end - 1,
          match.line + start,
        );
        controller.highlight(
          p1: first,
          p2: last,
          color: Color(keywordHighlights.colorArgb),
        );
      }
    } catch (_) {
      // Highlights are best-effort; buffer edits can invalidate anchors.
    }
  }

  void _applyCompletion(CommandCompletion completion) {
    final insertion = completionInsertion(_inputTracker.current, completion);
    if (insertion.isEmpty) return;
    _sendInput(insertion);
    _inputTracker.feed(insertion);
    _refreshCompletions();
    focus.requestFocus();
  }

  void _sendInput(String text) {
    widget.session.send(text);
    for (final target in widget.broadcastTargets) {
      target.send(text, record: false);
    }
  }

  void _focus() {
    if (mounted && widget.active) focus.requestFocus();
  }

  void _selectionForCopy() {
    if (!terminalAppearance.copyOnSelect || ended) return;
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(milliseconds: 180), () async {
      try {
        final selection = controller.selection;
        if (selection == null) return;
        final text = widget.session.terminal.buffer.getText(selection);
        if (text.isEmpty || text == _autoCopied) return;
        _autoCopied = text;
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        // A selection can be released together with its buffer range.
      }
    });
  }

  bool get ended => widget.session.ended;

  void sessionChanged() {
    if (mounted) setState(() {});
  }

  void appearanceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> editAppearance() async {
    await showDialog<void>(
      context: context,
      builder: (_) => TerminalAppearanceDialog(store: terminalAppearance),
    );
    if (mounted) _focus();
  }

  Future<void> searchHistory() async {
    await showDialog<void>(
      context: context,
      builder: (_) => TerminalSearch(
        snapshot: () {
          final lines = <String>[];
          final terminal = widget.session.terminal;
          for (var i = 0; i < terminal.buffer.lines.length; i++) {
            final line = terminal.buffer.lines[i];
            if (line.isWrapped && lines.isNotEmpty) {
              lines[lines.length - 1] += line.getText();
            } else {
              lines.add(line.getText());
            }
          }
          return lines;
        },
      ),
    );
    if (mounted) _focus();
  }

  Future<void> openSnippets() async {
    if (ended || widget.snippets == null) return;
    final command = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SnippetsDialog(store: widget.snippets!),
    );
    if (!mounted || ended || command == null) return;
    if (validateSnippetCommand(command) != null) return;
    widget.session.terminal.paste(command);
    _focus();
  }

  Future<void> _openLinkAt(PointerUpEvent event) async {
    if (ended) return;
    final keyboard = HardwareKeyboard.instance;
    final apple =
        Theme.of(context).platform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final primary = apple ? keyboard.isMetaPressed : keyboard.isControlPressed;
    if (!primary) return;
    try {
      final dynamic render = _terminalViewKey.currentState?.renderTerminal;
      if (render == null) return;
      final Offset local = render.globalToLocal(event.position) as Offset;
      final dynamic cell = render.getCellOffset(local);
      final y = cell.y as int;
      final x = cell.x as int;
      final lines = widget.session.terminal.buffer.lines;
      if (y < 0 || y >= lines.length) return;
      final text = lines[y].getText();
      for (final match in RegExp(r'''https?://[^\s"'<>]+''').allMatches(text)) {
        if (x < match.start - 1 || x > match.end + 1) continue;
        final url = match
            .group(0)!
            .replaceFirst(RegExp(r'[),.;!?，。；！？）】]+$'), '');
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {
      // Coordinate lookup is best-effort; normal selection must keep working.
    }
  }

  Future<void> openSelectedLink() async {
    final selection = controller.selection;
    if (selection == null) return;
    final value = widget.session.terminal.buffer.getText(selection).trim();
    final uri = Uri.tryParse(value);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请选中 http/https 链接')));
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> previewSelectedFile() async {
    final selection = controller.selection;
    if (selection == null) return;
    final selected = widget.session.terminal.buffer.getText(selection);
    final path = resolveRemotePath(selected, widget.session.currentDirectory);
    if (path == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请选中绝对路径，或等待终端上报当前目录')));
      return;
    }
    try {
      if (isSystemPreviewPath(path)) {
        final extension = path.contains('.')
            ? path.substring(path.lastIndexOf('.'))
            : '';
        final file = File(
          '${(await getTemporaryDirectory()).path}/wterm-preview-${DateTime.now().microsecondsSinceEpoch}$extension',
        );
        await native.downloadFile(
          connectionId: widget.session.connectionId,
          remotePath: path,
          localPath: file.path,
        );
        if (!mounted) return;
        if (Platform.isIOS) {
          final box = context.findRenderObject() as RenderBox;
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(file.path)],
              fileNameOverrides: [path.split('/').last],
              sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
            ),
          );
        } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
          await Process.run(Platform.isWindows ? 'explorer' : 'open', [
            file.path,
          ]);
        }
        return;
      }
      if (isImagePath(path)) {
        final file = File(
          '${(await getTemporaryDirectory()).path}/wterm-preview-${DateTime.now().microsecondsSinceEpoch}${path.substring(path.lastIndexOf("."))}',
        );
        await native.downloadFile(
          connectionId: widget.session.connectionId,
          remotePath: path,
          localPath: file.path,
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(path.split('/').last),
            content: InteractiveViewer(
              child: Image.file(
                file,
                errorBuilder: (_, _, _) => const Text('无法解码图片'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
        await file.delete().catchError((Object _) => file);
      } else {
        final text = await native.previewText(
          connectionId: widget.session.connectionId,
          path: path,
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(path.split('/').last),
            content: SizedBox(
              width: 680,
              height: 460,
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法预览：${userFacingError(e)}')));
      }
    }
  }

  Future<void> lookupSelectedIp() async {
    final selection = controller.selection;
    if (selection == null) return;
    final ip = widget.session.terminal.buffer.getText(selection).trim();
    if (!isIpv4(ip)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请选中有效的 IPv4 地址')));
      return;
    }
    try {
      final result = await lookupIp(ip);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('IP 归属 · $ip'),
          content: SelectableText(
            '国家/地区：${result.country}\n'
            '省/州：${result.region}\n'
            '城市：${result.city}\n'
            '运营商：${result.isp}\n'
            '组织：${result.org}\n'
            '时区：${result.timezone}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('查询失败：${userFacingError(e)}')));
      }
    }
  }

  Future<void> pinSelection() async {
    final selection = controller.selection;
    if (selection == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在终端中选中命令')));
      return;
    }
    final command = widget.session.terminal.buffer.getText(selection).trim();
    if (validateSnippetCommand(command) != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('只能固定单行命令')));
      return;
    }
    final hostScoped = widget.session.hostId.isNotEmpty;
    await pinnedCommands.pin(
      PinnedCommand(
        name: command.length > 32 ? '${command.substring(0, 32)}…' : command,
        command: command,
        hostId: hostScoped ? widget.session.hostId : '',
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(hostScoped ? '已固定到当前主机的命令条' : '已固定到终端底部')),
      );
    }
  }

  Future<void> saveSelectionAsSnippet() async {
    final store = widget.snippets;
    if (store == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未连接保险库，无法保存片段')));
      return;
    }
    final selection = controller.selection;
    if (selection == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在终端中选中命令')));
      return;
    }
    final command = widget.session.terminal.buffer.getText(selection).trim();
    if (validateSnippetCommand(command) != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('只能保存单行命令（最多 16 KiB）')));
      return;
    }
    final nameController = TextEditingController(
      text: command.length > 24 ? command.substring(0, 24) : command,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('存为命令片段'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '片段名称'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await store.saveSnippet('', name.trim(), command);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已保存到命令片段')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：${userFacingError(e)}')));
      }
    }
  }

  Future<void> shareImage() async {
    final boundary =
        _terminalBoundary.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    try {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('无法生成图片');
      final file = File(
        '${(await getTemporaryDirectory()).path}/wterm-terminal-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      try {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: 'W Term · ${widget.session.title}',
          ),
        );
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('图片已保存：${file.path}')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成图片失败：$e')));
      }
    }
  }

  Future<void> formatJson() async {
    final selection = controller.selection;
    if (selection == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在终端中选中 JSON')));
      return;
    }
    final raw = widget.session.terminal.buffer.getText(selection);
    String formatted;
    try {
      formatted = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } on FormatException {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('选中的内容不是有效 JSON')));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('JSON 格式化'),
        content: SizedBox(
          width: 640,
          height: 460,
          child: SingleChildScrollView(
            child: SelectableText(
              formatted,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: formatted)),
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAll() async {
    final buffer = StringBuffer();
    final lines = widget.session.terminal.buffer.lines;
    for (var i = 0; i < lines.length; i++) {
      buffer.writeln(lines[i].getText());
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
  }

  Future<void> copy() async {
    final selection = controller.selection;
    if (selection != null) {
      await Clipboard.setData(
        ClipboardData(text: widget.session.terminal.buffer.getText(selection)),
      );
    }
  }

  Future<void> paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted || ended) return;
    if (utf8.encode(text).length > 1024 * 1024) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('粘贴内容超过 1 MiB')));
      return;
    }
    if (text.contains('\n') || text.contains('\r')) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认多行粘贴'),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: SelectableText(
                text.length > 4000 ? '${text.substring(0, 4000)}\n…' : text,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('粘贴'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    widget.session.terminal.paste(text);
    _focus();
  }

  Future<void> zmodemUpload() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ZMODEM 发送文件'),
        content: const Text(
          '将在终端执行 rz，随后弹出本地文件选择并发送到远端。\n'
          '远端需要安装 lrzsz（rz/sz）；大文件传输期间请勿在终端输入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _sendInput('rz\n');
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已发送 rz；等待远端握手后选择本地文件')));
    }
  }

  Future<void> zmodemDownload() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ZMODEM 接收文件'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '远端文件路径',
            helperText: '将执行 sz 路径，随后选择本地保存位置',
            hintText: '/var/log/app.log',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('接收'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    final path = value?.trim() ?? '';
    if (path.isEmpty) return;
    if (RegExp(r'[\x00-\x1f]').hasMatch(path)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('路径包含不允许的控制字符')));
      }
      return;
    }
    final quoted = path.replaceAll("'", "'\\''");
    _sendInput("sz '$quoted'\n");
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已发送 sz；远端握手后选择本地保存位置')));
    }
  }

  Future<void> paneMenu(String value) async {
    if (value == 'reconnect') {
      widget.onReconnect?.call();
    } else if (value == 'ai') {
      await showDialog<void>(
        context: context,
        builder: (_) => AiAssistantDialog(session: widget.session),
      );
    } else if (value == 'share-image') {
      await shareImage();
    } else if (value == 'tmux') {
      await showDialog<void>(
        context: context,
        builder: (_) => TmuxDialog(
          connectionId: widget.session.connectionId,
          title: widget.session.title,
        ),
      );
    } else if (value == 'monitor') {
      await showDialog<void>(
        context: context,
        builder: (_) => SystemMonitorDialog(
          connectionId: widget.session.connectionId,
          title: widget.session.title,
        ),
      );
    } else if (value == 'horizontal') {
      widget.onSplitHorizontal?.call();
    } else if (value == 'vertical') {
      widget.onSplitVertical?.call();
    } else if (value == 'splitback') {
      widget.onSplitBack?.call();
    } else if (value == 'close') {
      widget.onClosePane?.call();
    } else if (value == 'copy') {
      await copy();
    } else if (value == 'paste') {
      await paste();
    } else if (value == 'theme') {
      await editAppearance();
    } else if (value == 'search') {
      await searchHistory();
    } else if (value == 'snippets') {
      await openSnippets();
    } else if (value == 'zmodem-upload') {
      await zmodemUpload();
    } else if (value == 'zmodem-download') {
      await zmodemDownload();
    } else if (value == 'highlight') {
      await showDialog<void>(
        context: context,
        builder: (_) => const KeywordHighlightDialog(),
      );
    }
  }

  Widget _toolbar() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 520;
      final broadcasting = widget.broadcastScope != BroadcastScope.off;
      final targets = widget.broadcastTargets.length;
      return Row(
        children: [
          Icon(
            ended ? Icons.circle_outlined : Icons.circle,
            color: ended ? Colors.grey : const Color(0xff71cba2),
            size: 8,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${ended ? '已断开 · ' : ''}${widget.session.title}'
              '${broadcasting ? ' · 广播 $targets' : ''}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: broadcasting
                    ? const Color(0xffffc66d)
                    : const Color(0xffa5adba),
                fontSize: 12,
              ),
            ),
          ),
          if (!compact && !ended && widget.active)
            _LatencyBadge(connectionId: widget.session.connectionId),
          if (ended && widget.onReconnect != null)
            IconButton(
              tooltip: '重新连接',
              onPressed: widget.onReconnect,
              icon: const Icon(
                Icons.refresh,
                color: Color(0xff71cba2),
                size: 17,
              ),
            ),
          if (widget.onBroadcastChanged != null)
            PopupMenuButton<BroadcastScope>(
              tooltip: '广播输入',
              icon: Icon(
                Icons.podcasts,
                color: broadcasting
                    ? const Color(0xffffc66d)
                    : const Color(0xffa5adba),
                size: 17,
              ),
              onSelected: widget.onBroadcastChanged,
              itemBuilder: (_) => [
                if (broadcasting)
                  PopupMenuItem(
                    enabled: false,
                    child: Text('当前输入目标：$targets 个会话'),
                  ),
                CheckedPopupMenuItem(
                  value: BroadcastScope.off,
                  checked: widget.broadcastScope == BroadcastScope.off,
                  child: const Text('关闭广播'),
                ),
                CheckedPopupMenuItem(
                  value: BroadcastScope.tab,
                  checked: widget.broadcastScope == BroadcastScope.tab,
                  child: const Text('当前标签内广播'),
                ),
                CheckedPopupMenuItem(
                  value: BroadcastScope.all,
                  checked: widget.broadcastScope == BroadcastScope.all,
                  child: const Text('全部已连接会话'),
                ),
              ],
            ),
          if (!compact) ...[
            if (widget.snippets != null)
              IconButton(
                tooltip: '命令片段',
                onPressed: ended ? null : openSnippets,
                icon: const Icon(
                  Icons.code,
                  color: Color(0xffa5adba),
                  size: 17,
                ),
              ),
            IconButton(
              tooltip: '终端外观',
              onPressed: editAppearance,
              icon: const Icon(
                Icons.palette_outlined,
                color: Color(0xffa5adba),
                size: 17,
              ),
            ),
            IconButton(
              tooltip: '搜索终端历史',
              onPressed: searchHistory,
              icon: const Icon(
                Icons.search,
                color: Color(0xffa5adba),
                size: 17,
              ),
            ),
            IconButton(
              tooltip: '复制选中内容',
              onPressed: copy,
              icon: const Icon(Icons.copy, color: Color(0xffa5adba), size: 17),
            ),
            IconButton(
              tooltip: '粘贴',
              onPressed: ended ? null : paste,
              icon: const Icon(
                Icons.content_paste,
                color: Color(0xffa5adba),
                size: 17,
              ),
            ),
          ],
          PopupMenuButton<String>(
            tooltip: '窗格操作',
            icon: const Icon(
              Icons.more_vert,
              color: Color(0xffa5adba),
              size: 17,
            ),
            onSelected: paneMenu,
            itemBuilder: (_) => [
              if (ended && widget.onReconnect != null)
                const PopupMenuItem(value: 'reconnect', child: Text('重新连接')),
              if (compact) ...[
                const PopupMenuItem(value: 'copy', child: Text('复制选中内容')),
                if (!ended)
                  const PopupMenuItem(value: 'paste', child: Text('粘贴')),
                if (widget.snippets != null && !ended)
                  const PopupMenuItem(value: 'snippets', child: Text('命令片段')),
                const PopupMenuItem(value: 'theme', child: Text('终端外观')),
                const PopupMenuItem(value: 'search', child: Text('搜索终端历史')),
                const PopupMenuItem(value: 'highlight', child: Text('关键字高亮')),
                const PopupMenuDivider(),
              ],
              if (!ended) ...[
                const PopupMenuItem(
                  value: 'zmodem-upload',
                  child: Text('ZMODEM 发送文件…'),
                ),
                const PopupMenuItem(
                  value: 'zmodem-download',
                  child: Text('ZMODEM 接收文件…'),
                ),
                const PopupMenuDivider(),
              ],
              const PopupMenuItem(value: 'highlight', child: Text('关键字高亮…')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'horizontal', child: Text('水平分屏')),
              const PopupMenuItem(value: 'vertical', child: Text('垂直分屏')),
              if (widget.onSplitBack != null)
                const PopupMenuItem(value: 'splitback', child: Text('拆回标签')),
              const PopupMenuItem(value: 'close', child: Text('关闭窗格')),
            ],
          ),
        ],
      );
    },
  );

  @override
  void dispose() {
    terminalAppearance.removeListener(appearanceChanged);
    widget.session.removeListener(sessionChanged);
    pinnedCommands.removeListener(sessionChanged);
    _copyTimer?.cancel();
    _highlightTimer?.cancel();
    controller.removeListener(_selectionForCopy);
    pluginSettings.removeListener(_pluginSettingsChanged);
    keywordHighlights.removeListener(_highlightSettingsChanged);
    for (final highlight in List.of(controller.highlights)) {
      highlight.dispose();
    }
    widget.session.terminal.onOutput = widget.session.send;
    focus.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => widget.onActivate(),
    child: Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: widget.active
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Column(
        children: [
          Container(
            color: widget.broadcastScope == BroadcastScope.off
                ? const Color(0xff161c24)
                : const Color(0xff2a2115),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _toolbar(),
          ),
          Expanded(
            child: ColoredBox(
              color: terminalAppearance.activeTheme.background,
              child: RepaintBoundary(
                key: _terminalBoundary,
                child: Listener(
                  onPointerUp: _openLinkAt,
                  child: TerminalView(
                    key: _terminalViewKey,
                    deleteDetection:
                        Theme.of(context).platform == TargetPlatform.iOS ||
                        Theme.of(context).platform == TargetPlatform.android,
                    widget.session.terminal,
                    theme: terminalAppearance.activeTheme,
                    controller: controller,
                    focusNode: focus,
                    onKeyEvent: (_, event) {
                      if (event is KeyDownEvent && widget.onShortcut != null) {
                        final keyboard = HardwareKeyboard.instance;
                        final apple =
                            Theme.of(context).platform ==
                                TargetPlatform.macOS ||
                            Theme.of(context).platform == TargetPlatform.iOS;
                        final primary = apple
                            ? keyboard.isMetaPressed
                            : keyboard.isControlPressed &&
                                  keyboard.isShiftPressed;
                        if (event.logicalKey == LogicalKeyboardKey.f11) {
                          widget.onShortcut!('focus', null);
                          return KeyEventResult.handled;
                        }
                        if (primary) {
                          final key = event.logicalKey;
                          if (key == LogicalKeyboardKey.keyT) {
                            widget.onShortcut!('new', null);
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.keyW) {
                            widget.onShortcut!('close-tab', null);
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.keyO &&
                              keyboard.isShiftPressed) {
                            widget.onShortcut!('sessions', null);
                            return KeyEventResult.handled;
                          }
                          if (keyboard.isShiftPressed &&
                              key == LogicalKeyboardKey.bracketLeft) {
                            widget.onShortcut!('prev-tab', null);
                            return KeyEventResult.handled;
                          }
                          if (keyboard.isShiftPressed &&
                              key == LogicalKeyboardKey.bracketRight) {
                            widget.onShortcut!('next-tab', null);
                            return KeyEventResult.handled;
                          }
                          const digits = [
                            LogicalKeyboardKey.digit1,
                            LogicalKeyboardKey.digit2,
                            LogicalKeyboardKey.digit3,
                            LogicalKeyboardKey.digit4,
                            LogicalKeyboardKey.digit5,
                            LogicalKeyboardKey.digit6,
                            LogicalKeyboardKey.digit7,
                            LogicalKeyboardKey.digit8,
                            LogicalKeyboardKey.digit9,
                          ];
                          final index = digits.indexOf(key);
                          if (index >= 0) {
                            widget.onShortcut!('tab', index);
                            return KeyEventResult.handled;
                          }
                        }
                      }
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.keyF &&
                          (HardwareKeyboard.instance.isMetaPressed ||
                              (HardwareKeyboard.instance.isControlPressed &&
                                  HardwareKeyboard.instance.isShiftPressed))) {
                        unawaited(searchHistory());
                        return KeyEventResult.handled;
                      }
                      if (event is KeyDownEvent &&
                          HardwareKeyboard.instance.isMetaPressed) {
                        if (event.logicalKey == LogicalKeyboardKey.keyV) {
                          unawaited(paste());
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.keyC) {
                          unawaited(copy());
                          return KeyEventResult.handled;
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    autofocus: false,
                    readOnly: ended,
                    padding: const EdgeInsets.all(12),
                    textStyle: TerminalStyle(
                      fontSize: terminalAppearance.fontSize.toDouble(),
                      fontFamily:
                          Theme.of(context).platform == TargetPlatform.windows
                          ? 'Microsoft YaHei'
                          : 'Menlo',
                      fontFamilyFallback:
                          Theme.of(context).platform == TargetPlatform.windows
                          ? const ['Cascadia Mono', 'Consolas', 'monospace']
                          : const ['monospace'],
                    ),
                    onSecondaryTapDown: (details, _) async {
                      final selected = await showMenu<String>(
                        context: context,
                        position: RelativeRect.fromLTRB(
                          details.globalPosition.dx,
                          details.globalPosition.dy,
                          details.globalPosition.dx,
                          details.globalPosition.dy,
                        ),
                        items: [
                          const PopupMenuItem(value: 'copy', child: Text('复制')),
                          const PopupMenuItem(
                            value: 'copy-all',
                            child: Text('全选并复制'),
                          ),
                          if (!ended)
                            const PopupMenuItem(
                              value: 'paste',
                              child: Text('粘贴'),
                            ),
                          if (widget.onOpenFiles != null)
                            const PopupMenuItem(
                              value: 'files',
                              child: Text('打开文件面板'),
                            ),
                          if (pluginSettings.jsonFormatter)
                            const PopupMenuItem(
                              value: 'json',
                              child: Text('格式化选中 JSON'),
                            ),
                          if (pluginSettings.ipLookup)
                            const PopupMenuItem(
                              value: 'ip',
                              child: Text('查询选中 IP 归属'),
                            ),
                          if (pluginSettings.filePreview)
                            const PopupMenuItem(
                              value: 'preview-file',
                              child: Text('预览选中文件'),
                            ),
                          const PopupMenuItem(
                            value: 'open-link',
                            child: Text('打开选中链接'),
                          ),
                          const PopupMenuItem(
                            value: 'pin',
                            child: Text('固定选中命令'),
                          ),
                          if (widget.snippets != null)
                            const PopupMenuItem(
                              value: 'save-snippet',
                              child: Text('存为命令片段'),
                            ),
                          const PopupMenuItem(
                            value: 'share-image',
                            child: Text('分享终端为图片'),
                          ),
                          const PopupMenuItem(
                            value: 'plugins',
                            child: Text('插件设置'),
                          ),
                        ],
                      );
                      if (selected == 'copy') {
                        await copy();
                      } else if (selected == 'copy-all') {
                        await _copyAll();
                      } else if (selected == 'paste') {
                        await paste();
                      } else if (selected == 'files') {
                        widget.onOpenFiles?.call();
                      } else if (selected == 'json') {
                        await formatJson();
                      } else if (selected == 'ip') {
                        await lookupSelectedIp();
                      } else if (selected == 'preview-file') {
                        await previewSelectedFile();
                      } else if (selected == 'open-link') {
                        await openSelectedLink();
                      } else if (selected == 'pin') {
                        await pinSelection();
                      } else if (selected == 'save-snippet') {
                        await saveSelectionAsSnippet();
                      } else if (selected == 'share-image') {
                        await shareImage();
                      } else if (selected == 'plugins') {
                        if (!context.mounted) return;
                        await showDialog<void>(
                          context: context,
                          builder: (_) => const PluginSettingsDialog(),
                        );
                      }
                    },
                  ),
                ),
              ),
            ),
          ),
          if (widget.active && !ended && _completions.isNotEmpty)
            Container(
              height: 38,
              color: const Color(0xff141a21),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                children: [
                  for (final completion in _completions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        label: Text(
                          '${completion.value} · ${completion.description}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        onPressed: () => _applyCompletion(completion),
                      ),
                    ),
                ],
              ),
            ),
          ListenableBuilder(
            listenable: pinnedCommands,
            builder: (context, _) {
              final pins = pinnedCommands.forHost(widget.session.hostId);
              if (pins.isEmpty) return const SizedBox.shrink();
              return Container(
                height: 40,
                color: const Color(0xff161c24),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final pin in pins)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, top: 5),
                        child: Material(
                          type: MaterialType.transparency,
                          child: InputChip(
                            label: Text(
                              pin.name,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onPressed: ended
                                ? null
                                : () {
                                    _sendInput('${pin.command}\n');
                                    _focus();
                                  },
                            onDeleted: () => pinnedCommands.unpin(pin),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          if (MediaQuery.sizeOf(context).width < 900)
            Container(
              color: const Color(0xff161c24),
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final key in const [
                    ('Esc', '\x1b'),
                    ('Tab', '\t'),
                    ('Ctrl-C', '\x03'),
                    ('Ctrl-D', '\x04'),
                    ('Ctrl-L', '\x0c'),
                    ('↑', '\x1b[A'),
                    ('↓', '\x1b[B'),
                    ('←', '\x1b[D'),
                    ('→', '\x1b[C'),
                  ])
                    TextButton(
                      onPressed: ended
                          ? null
                          : () {
                              _sendInput(key.$2);
                              _focus();
                            },
                      child: Text(
                        key.$1,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class _LatencyBadge extends StatefulWidget {
  final String connectionId;
  const _LatencyBadge({required this.connectionId});
  @override
  State<_LatencyBadge> createState() => _LatencyBadgeState();
}

class _LatencyBadgeState extends State<_LatencyBadge> {
  Timer? timer;
  int? millis;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 10), (_) => check());
    Future<void>.delayed(const Duration(seconds: 2), check);
  }

  Future<void> check() async {
    final watch = Stopwatch()..start();
    try {
      await native.runCommand(
        connectionId: widget.connectionId,
        command: 'true',
      );
      watch.stop();
      if (mounted) setState(() => millis = watch.elapsedMilliseconds);
    } catch (_) {
      if (mounted) setState(() => millis = null);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = millis;
    final color = value == null
        ? Colors.grey
        : value < 100
        ? const Color(0xff71cba2)
        : value < 300
        ? const Color(0xffffc66d)
        : const Color(0xffff8a80);
    return Tooltip(
      message: value == null ? 'SSH 延迟未知' : 'SSH 命令往返延迟 $value ms',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.network_check, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              value == null ? '--' : '$value ms',
              style: TextStyle(color: color, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
