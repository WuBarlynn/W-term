import '../app/snippet_store.dart';
import '../app/command_completion.dart';
import '../app/keyword_highlights.dart';
import '../app/shell_integration.dart';
import 'keyword_highlight_dialog.dart';
import 'snippets_dialog.dart';
import 'terminal_search.dart';
import 'image_preview_dialog.dart';
import 'terminal_share_dialog.dart';
import '../app/terminal_appearance.dart';
import '../app/font_catalog.dart';
import 'terminal_appearance_dialog.dart';
import 'system_monitor_dialog.dart';
import 'tmux_dialog.dart';
import 'ai_assistant_dialog.dart';
import 'plugin_settings_dialog.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
import '../app/system_metrics.dart';
import '../app/shortcuts.dart';
import '../app/terminal_links.dart';
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
  final int broadcastTargetCount;
  final String? paneDragData;
  final List<String> hostTags;
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
    this.broadcastTargetCount = 0,
    this.paneDragData,
    this.hostTags = const [],
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
  final compose = TextEditingController();
  final focus = FocusNode();
  final _terminalBoundary = GlobalKey();
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  final _linkRepaint = ValueNotifier<int>(0);
  bool _wasActive = false;
  Timer? _copyTimer;
  String? _autoCopied;
  Timer? _selectionMenuTimer;
  OverlayEntry? _selectionMenuOverlay;
  String _dismissedSelectionMenu = '';
  bool _contextMenuOpen = false;
  final _inputTracker = TerminalInputTracker();
  Timer? _highlightTimer;
  static const _imeChannel = MethodChannel('dev.wterm/biometrics');
  List<CommandCompletion> _completions = const [];
  String _completionSignature = '';
  String? _pendingShellAction;
  String? _lastReportedShell;
  Timer? _shellProbeTimer;
  Timer? _statusTimer;
  bool _statusSampling = false;
  ProcSnapshot? _lastProc;
  final _connectedAt = DateTime.now();
  String _machineInfo = '';
  Timer? _infoTimer;
  Timer? _cursorTimer;
  bool _cursorVisible = true;
  double? _cpuPercent, _memoryPercent;
  double? _load1;
  int? _diskPercent;
  int? _latencyMs;
  int _hoverPathLine = -1;
  int _hoverPathStart = -1;
  int _hoverPathEnd = -1;
  @override
  void initState() {
    super.initState();
    terminalAppearance.addListener(appearanceChanged);
    widget.session.addListener(sessionChanged);
    pinnedCommands.addListener(sessionChanged);
    controller.addListener(_selectionForCopy);
    controller.addListener(_selectionForMenu);
    pluginSettings.addListener(_pluginSettingsChanged);
    keywordHighlights.addListener(_highlightSettingsChanged);
    focus.addListener(_imeFocusChanged);
    widget.session.addInputListener(_inputObserved);
    widget.session.terminal.addListener(_markLinksDirty);
    _updateCursorBlink();
    _wasActive = widget.active;
    _lastReportedShell = widget.session.reportedShell;
    if (!widget.session.isLocal) {
      _statusTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_sampleStatus()),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_sampleStatus());
        if (mounted && pluginSettings.showMachineInfo) {
          unawaited(_loadMachineInfo());
        }
      });
    }
    if (pluginSettings.showSessionInfo) {
      _infoTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) {
          if (mounted) setState(() {});
        },
      );
    }
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
      oldWidget.session.removeInputListener(_inputObserved);
      oldWidget.session.terminal.removeListener(_markLinksDirty);
      widget.session.addListener(sessionChanged);
      widget.session.addInputListener(_inputObserved);
      widget.session.terminal.addListener(_markLinksDirty);
      _lastReportedShell = widget.session.reportedShell;
      _shellProbeTimer?.cancel();
      _pendingShellAction = null;
    }
    if (widget.active && !_wasActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus());
    }
    if (!widget.active) _removeSelectionMenu();
    _wasActive = widget.active;
  }

  /// Tracks input for completions/highlights. Sending and broadcasting stay in
  /// [TerminalSession] so pane reconstruction cannot break the input route.
  void _inputObserved(String text) {
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

  void _updateCursorBlink() {
    _cursorTimer?.cancel();
    _cursorTimer = null;
    if (terminalAppearance.cursorBlink) {
      _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() => _cursorVisible = !_cursorVisible);
      });
    } else {
      _cursorVisible = true;
    }
  }

  void _pluginSettingsChanged() {
    if (!pluginSettings.selectionMenu) _removeSelectionMenu();
    if (!pluginSettings.commandCompletion) _refreshCompletions();
    if (pluginSettings.showMachineInfo &&
        _machineInfo.isEmpty &&
        !widget.session.isLocal) {
      unawaited(_loadMachineInfo());
    }
    _applyImeState();
    if (mounted) setState(() {});
  }

  Future<void> _loadMachineInfo() async {
    if (widget.session.isLocal || _machineInfo.isNotEmpty) return;
    try {
      final raw = await native.runCommand(
        connectionId: widget.session.connectionId,
        command: "sh -c 'uname -srm 2>/dev/null; hostname 2>/dev/null'",
      );
      final lines = raw
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .take(2)
          .toList();
      if (!mounted || lines.isEmpty) return;
      setState(() => _machineInfo = lines.join(' · '));
    } catch (_) {
      // Machine details are optional; the session remains usable.
    }
  }

  String _sessionDuration() {
    final elapsed = DateTime.now().difference(_connectedAt);
    final hours = elapsed.inHours.toString().padLeft(2, '0');
    final minutes = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  Widget _infoBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Wrap(
      spacing: 18,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (pluginSettings.showSessionInfo)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 13),
              const SizedBox(width: 4),
              Text(
                '${widget.session.username}@${widget.session.host} · 已连接 ${_sessionDuration()}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        if (pluginSettings.showMachineInfo && !widget.session.isLocal)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.computer, size: 13),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(
                  _machineInfo.isEmpty ? '正在读取机器信息…' : _machineInfo,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
      ],
    ),
  );

  void _markLinksDirty() {
    _linkRepaint.value++;
  }

  void _imeFocusChanged() {
    _applyImeState();
  }

  void _applyImeState() {
    if (!(Theme.of(context).platform == TargetPlatform.macOS)) return;
    unawaited(
      _imeChannel
          .invokeMethod<void>(
            'setAsciiInput',
            focus.hasFocus && pluginSettings.imeAutoEnglish,
          )
          .catchError((Object _) {}),
    );
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
      if (!keywordHighlights.enabled ||
          (keywordHighlights.keywords.isEmpty &&
              keywordHighlights.hostRules.isEmpty)) {
        return;
      }
      final lines = widget.session.terminal.buffer.lines;
      final start = (lines.length - 3000).clamp(0, lines.length);
      final texts = [
        for (var index = start; index < lines.length; index++)
          lines[index].getText(),
      ];
      final matches = [
        ...findKeywordMatches(texts, keywordHighlights.keywords),
        ...findRegexMatches(
          texts,
          keywordHighlights.hostRules,
          widget.hostTags.toSet(),
        ),
      ];
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
    focus.requestFocus();
  }

  void _sendInput(String text) => widget.session.sendInput(text);

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

  String _selectionSignature(BufferRange selection) =>
      '${selection.begin.x},${selection.begin.y}-'
      '${selection.end.x},${selection.end.y}';

  void _selectionForMenu() {
    _selectionMenuTimer?.cancel();
    final selection = controller.selection;
    if (selection == null) {
      _dismissedSelectionMenu = '';
      _removeSelectionMenu();
      return;
    }
    if (!pluginSettings.selectionMenu ||
        !widget.active ||
        ended ||
        _contextMenuOpen) {
      _removeSelectionMenu();
      return;
    }
    final signature = _selectionSignature(selection);
    if (signature == _dismissedSelectionMenu) {
      _removeSelectionMenu();
      return;
    }
    _selectionMenuTimer = Timer(const Duration(milliseconds: 450), () {
      final current = controller.selection;
      if (!mounted || !widget.active || !pluginSettings.selectionMenu) return;
      if (current == null || _selectionSignature(current) != signature) return;
      _showSelectionMenu(current);
    });
  }

  void _showSelectionMenu(BufferRange selection) {
    final render = _terminalViewKey.currentState?.renderTerminal;
    final text = widget.session.terminal.buffer.getText(selection).trim();
    if (!mounted || render == null) return;
    if (text.isEmpty) return;
    _removeSelectionMenu();
    final anchor = render.localToGlobal(render.getOffset(selection.end));
    final media = MediaQuery.sizeOf(context);
    final canPin = pluginSettings.selectionPin;
    final canSnippet = widget.snippets != null && pluginSettings.selectionSnippet;
    final canShare = pluginSettings.selectionShare;
    final canJson = pluginSettings.jsonFormatter && isJsonText(text);
    final canIp = pluginSettings.ipLookup && isIpv4(text);
    final count =
        1 +
        (canPin ? 1 : 0) +
        (canSnippet ? 1 : 0) +
        (canShare ? 1 : 0) +
        (canJson ? 1 : 0) +
        (canIp ? 1 : 0);
    final width = 8.0 + count * 40.0;
    final left = anchor.dx
        .clamp(8.0, math.max(8.0, media.width - width - 8.0))
        .toDouble();
    final above = anchor.dy - 52;
    final top = above >= 8
        ? above
        : math.min(anchor.dy + 24, math.max(8.0, media.height - 56.0));
    final overlay = Overlay.of(context, rootOverlay: true);
    _selectionMenuOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        child: TapRegion(
          onTapOutside: (_) => _dismissSelectionMenu(),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _selectionMenuButton(Icons.copy, '复制', copy),
                if (canPin)
                  _selectionMenuButton(
                    Icons.push_pin_outlined,
                    '固定选中命令',
                    pinSelection,
                  ),
                if (canSnippet)
                  _selectionMenuButton(
                    Icons.bookmark_add_outlined,
                    '存为命令片段',
                    saveSelectionAsSnippet,
                  ),
                if (canShare)
                  _selectionMenuButton(
                    Icons.ios_share,
                    '分享为图片',
                    shareImage,
                  ),
                if (canJson)
                  _selectionMenuButton(
                    Icons.data_object,
                    '格式化选中 JSON',
                    formatJson,
                  ),
                if (canIp)
                  _selectionMenuButton(
                    Icons.public,
                    '查询选中 IP 归属',
                    lookupSelectedIp,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(_selectionMenuOverlay!);
  }

  Widget _selectionMenuButton(
    IconData icon,
    String tooltip,
    Future<void> Function() action,
  ) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 18),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
    onPressed: () async {
      _dismissSelectionMenu();
      await action();
    },
  );

  void _dismissSelectionMenu() {
    final selection = controller.selection;
    if (selection != null) {
      _dismissedSelectionMenu = _selectionSignature(selection);
    }
    _removeSelectionMenu();
  }

  void _removeSelectionMenu() {
    _selectionMenuTimer?.cancel();
    _selectionMenuOverlay?.remove();
    _selectionMenuOverlay = null;
  }

  bool get ended => widget.session.ended;

  String get _terminalFontFamily {
    final configured = terminalAppearance.terminalFont.trim();
    return configured.isEmpty ? platformDefaultTerminalFont() : configured;
  }

  List<String> get _terminalFontFallback {
    final cjk = terminalAppearance.cjkFont.trim();
    final windows = Theme.of(context).platform == TargetPlatform.windows;
    return [
      if (cjk.isNotEmpty) cjk,
      if (windows) ...[
        'JetBrains Mono',
        'Consolas',
        'Noto Sans SC',
        'Microsoft YaHei UI',
        'Microsoft YaHei',
      ] else if (Theme.of(context).platform == TargetPlatform.macOS ||
          Theme.of(context).platform == TargetPlatform.iOS) ...[
        'PingFang SC',
        'Noto Sans SC',
        'Menlo',
      ] else
        'Noto Sans SC',
      'monospace',
    ];
  }

  void sessionChanged() {
    final reported = widget.session.reportedShell;
    if (reported != null && reported != _lastReportedShell) {
      _lastReportedShell = reported;
      _applyReportedShell();
    }
    if (mounted) setState(() {});
  }

  Future<void> _autoShellIntegration(String action) async {
    if (widget.session.isLocal) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本地终端不需要注入远程 shell 钩子')));
      }
      return;
    }
    _pendingShellAction = action;
    _lastReportedShell = null;
    _shellProbeTimer?.cancel();
    _shellProbeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _pendingShellAction == null) return;
      _pendingShellAction = null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未能自动识别 shell，请重新打开菜单手动选择 bash/zsh/fish')),
      );
    });
    widget.session.send('$shellProbeCommand\n');
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在检测当前 shell…')));
    }
  }

  void _applyReportedShell() {
    final action = _pendingShellAction;
    final shell = widget.session.reportedShell;
    if (action == null || shell == null) return;
    _pendingShellAction = null;
    _shellProbeTimer?.cancel();
    if (shell != 'bash' && shell != 'zsh' && shell != 'fish') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检测到 $shell，请重新打开菜单手动选择支持的 shell')),
        );
      }
      return;
    }
    final command = action == 'directory'
        ? shellDirectoryIntegrationCommandFor(shell)
        : shellCommandFinishedIntegrationCommandFor(shell);
    widget.session.send('$command\n');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '检测到 $shell，已发送${action == 'directory' ? '目录上报' : '命令完成通知'}钩子',
          ),
        ),
      );
    }
  }

  void appearanceChanged() {
    _updateCursorBlink();
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

  Future<void> _zoom(int delta) async {
    final next = delta == 0
        ? 13
        : (terminalAppearance.fontSize + delta).clamp(10, 28);
    await terminalAppearance.save(terminalAppearance.palette, next);
  }

  void _sendCompose() {
    final text = compose.text;
    if (text.trim().isEmpty) return;
    _sendInput('$text\n');
    compose.clear();
    if (mounted) setState(() {});
    _focus();
  }

  Future<void> _sampleStatus() async {
    if (!mounted || _statusSampling || !pluginSettings.showStatusBar) return;
    _statusSampling = true;
    final watch = Stopwatch()..start();
    try {
      final raw = await native.runCommand(
        connectionId: widget.session.connectionId,
        command:
            "sh -c 'head -1 /proc/stat; grep -E \"^(MemTotal|MemAvailable|MemFree|Buffers|Cached):\" /proc/meminfo; cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null; df -P / 2>/dev/null | tail -1'",
      );
      final snapshot = ProcSnapshot.parse(raw);
      final host = HostMetrics.parse(raw);
      if (!mounted) return;
      setState(() {
        _latencyMs = watch.elapsedMilliseconds;
        if (snapshot != null) {
          _cpuPercent = cpuUsageBetween(_lastProc, snapshot);
          _memoryPercent = snapshot.memoryUsedPercent;
          _lastProc = snapshot;
        }
        if (host != null) {
          _load1 = host.load1;
          _diskPercent = host.diskUsedPercent;
        }
      });
    } catch (_) {
      // Remote metrics are optional and must never disturb the terminal.
    } finally {
      _statusSampling = false;
    }
  }

  Widget _statusBar() => Container(
    height: 24,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final showHostMetrics = constraints.maxWidth >= 560;
        return Row(
          children: [
            const Icon(Icons.speed, size: 13),
            const SizedBox(width: 4),
            Text(
              _latencyMs == null ? '—' : '$_latencyMs ms',
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(width: 14),
            const Icon(Icons.memory, size: 13),
            const SizedBox(width: 4),
            Text(
              'CPU ${formatPercent(_cpuPercent)}',
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(width: 14),
            const Icon(Icons.storage, size: 13),
            const SizedBox(width: 4),
            Text(
              '内存 ${formatPercent(_memoryPercent)}',
              style: const TextStyle(fontSize: 11),
            ),
            if (showHostMetrics && _load1 != null) ...[
              const SizedBox(width: 14),
              const Icon(Icons.bolt, size: 13),
              const SizedBox(width: 4),
              Text(
                '负载 ${_load1!.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
            if (showHostMetrics && _diskPercent != null) ...[
              const SizedBox(width: 14),
              const Icon(Icons.sd_storage, size: 13),
              const SizedBox(width: 4),
              Text(
                '磁盘 $_diskPercent%',
                style: const TextStyle(fontSize: 11),
              ),
            ],
            const Spacer(),
            if (!showHostMetrics)
              const Text('每 10 秒采样', style: TextStyle(fontSize: 10)),
          ],
        );
      },
    ),
  );

  void _hoverPath(PointerHoverEvent event) {
    if (!pluginSettings.filePreview) return;
    try {
      final dynamic render = _terminalViewKey.currentState?.renderTerminal;
      if (render == null) return;
      final Offset local = render.globalToLocal(event.position) as Offset;
      final dynamic cell = render.getCellOffset(local);
      final y = cell.y as int;
      final x = cell.x as int;
      final lines = widget.session.terminal.buffer.lines;
      if (y < 0 || y >= lines.length) {
        _clearHoverPath();
        return;
      }
      final span = findPathSpanAt(lines[y].getText(), x);
      final start = span?.start ?? -1;
      final end = span?.end ?? -1;
      if (y == _hoverPathLine &&
          start == _hoverPathStart &&
          end == _hoverPathEnd) {
        return;
      }
      _hoverPathLine = y;
      _hoverPathStart = start;
      _hoverPathEnd = end;
      _linkRepaint.value++;
    } catch (_) {
      _clearHoverPath();
    }
  }

  void _clearHoverPath() {
    if (_hoverPathLine < 0 && _hoverPathStart < 0) return;
    _hoverPathLine = -1;
    _hoverPathStart = -1;
    _hoverPathEnd = -1;
    _linkRepaint.value++;
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
      if (pluginSettings.filePreview && !widget.session.isLocal) {
        final candidate = findPathAt(text, x);
        final path = candidate == null
            ? null
            : resolveRemotePath(candidate, widget.session.currentDirectory);
        if (path != null) await previewRemotePath(path);
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
    await previewRemotePath(path);
  }

  Future<void> previewRemotePath(String path) async {
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
          builder: (_) => ImagePreviewDialog(
            title: path.split('/').last,
            path: file.path,
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
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: monoFontFallback,
                    fontSize: 12,
                  ),
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
      final result = await lookupIp(ip, cache: defaultIpLookupCache);
      if (!mounted) return;
      final details = <String>[
        if (result.local)
          '地址类型：${result.country}'
        else
          '国家/地区：${result.country}',
        if (result.region.isNotEmpty) '省/州：${result.region}',
        if (result.city.isNotEmpty) '城市：${result.city}',
        if (result.isp.isNotEmpty) '运营商：${result.isp}',
        if (result.org.isNotEmpty) '组织：${result.org}',
        if (result.asn.isNotEmpty) 'ASN：${result.asn}',
        if (result.timezone.isNotEmpty) '时区：${result.timezone}',
        if (result.latitude != null && result.longitude != null)
          '经纬度：${result.latitude!.toStringAsFixed(4)}, '
              '${result.longitude!.toStringAsFixed(4)}',
        if (result.cached)
          result.stale ? '来源：本地缓存（网络查询失败）' : '来源：本地缓存',
        if (result.local) '来源：本地判定（未联网）',
      ];
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('IP 归属 · $ip'),
          content: SelectableText(details.join('\n')),
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
    final hostId = widget.session.hostId;
    var scope = hostId.isNotEmpty ? 'host' : '';
    if (widget.hostTags.isNotEmpty) {
      final selected = await showDialog<String>(
        context: context,
        builder: (context) {
          var value = scope;
          return StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: const Text('固定命令的位置'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.public, size: 20),
                      title: const Text('所有主机（全局）'),
                      trailing: value.isEmpty
                          ? const Icon(Icons.check, size: 18)
                          : null,
                      onTap: () => update(() => value = ''),
                    ),
                    if (hostId.isNotEmpty)
                      ListTile(
                        leading: const Icon(Icons.dns_outlined, size: 20),
                        title: const Text('仅当前主机'),
                        trailing: value == 'host'
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () => update(() => value = 'host'),
                      ),
                    for (final tag in widget.hostTags)
                      ListTile(
                        leading: const Icon(Icons.label_outline, size: 20),
                        title: Text('标签：$tag'),
                        trailing: value == 'tag:$tag'
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () => update(() => value = 'tag:$tag'),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, value),
                  child: const Text('固定'),
                ),
              ],
            ),
          );
        },
      );
      if (selected == null) return;
      scope = selected;
    }
    final tag = scope.startsWith('tag:') ? scope.substring(4) : '';
    await pinnedCommands.pin(
      PinnedCommand(
        name: command.length > 32 ? '${command.substring(0, 32)}…' : command,
        command: command,
        hostId: scope == 'host' ? hostId : '',
        tag: tag,
      ),
    );
    if (mounted) {
      final where = tag.isNotEmpty
          ? '标签「$tag」的命令条'
          : scope == 'host'
          ? '当前主机的命令条'
          : '终端底部（全局）';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已固定到$where')));
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

  Future<void> shareImageTemplates() async {
    final raw = <String>[];
    final bufferLines = widget.session.terminal.buffer.lines;
    for (var index = 0; index < bufferLines.length; index++) {
      final line = bufferLines[index];
      if (line.isWrapped && raw.isNotEmpty) {
        raw[raw.length - 1] += line.getText();
      } else {
        raw.add(line.getText());
      }
    }
    final lines = raw.where((line) => line.trim().isNotEmpty).toList();
    if (lines.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('终端没有可分享的内容')));
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => TerminalShareDialog(
        title: widget.session.title,
        lines: lines,
        theme: terminalAppearance.activeTheme,
        fontFamily: _terminalFontFamily,
        fontSize: terminalAppearance.fontSize.toDouble(),
      ),
    );
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
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: monoFontFallback,
                fontSize: 12,
              ),
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
    if (widget.session.isLocal &&
        const {'ai', 'tmux', 'monitor'}.contains(value)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本地终端不支持该远程功能')));
      return;
    }
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
    } else if (value == 'shell-integration') {
      await shellIntegration();
    } else if (value == 'command-finished-hook') {
      await commandFinishedHook();
    }
  }

  Future<void> shellIntegration() async {
    final shell = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启用目录上报'),
        content: const Text(
          '将向当前 shell 注入 OSC 7 提示符钩子，让文件面板跟随终端目录。'
          '只对当前会话生效，不会修改 shell 启动文件。请选择远程 shell 类型。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'auto'),
            child: const Text('自动检测'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'fish'),
            child: const Text('fish'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'posix'),
            child: const Text('bash / zsh'),
          ),
        ],
      ),
    );
    if (shell == null) return;
    if (shell == 'auto') {
      await _autoShellIntegration('directory');
      return;
    }
    _sendInput('${shellDirectoryIntegrationCommandFor(shell)}\n');
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已发送目录上报设置；文件面板可开启跟随')));
    }
  }

  Future<void> commandFinishedHook() async {
    final shell = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('命令完成通知钩子'),
        content: const Text(
          '把 OSC 133;D 完成标记注入当前 shell，使任务完成通知在命令结束时立即触发，'
          '而不是等待输出空闲。只对当前会话生效，不会修改 shell 启动文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'auto'),
            child: const Text('自动检测'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'fish'),
            child: const Text('fish'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'zsh'),
            child: const Text('zsh'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'bash'),
            child: const Text('bash'),
          ),
        ],
      ),
    );
    if (shell == null) return;
    if (shell == 'auto') {
      await _autoShellIntegration('notify');
      return;
    }
    _sendInput('${shellCommandFinishedIntegrationCommandFor(shell)}\n');
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已发送命令完成通知钩子；长命令结束时会精确提示')));
    }
  }

  Widget _titleContent(String text, bool broadcasting) => Row(
    children: [
      Flexible(
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: broadcasting
                ? const Color(0xffffc66d)
                : const Color(0xffa5adba),
            fontSize: 12,
          ),
        ),
      ),
      if (widget.paneDragData != null) ...[
        const SizedBox(width: 4),
        MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Icon(
            Icons.drag_indicator,
            size: 14,
            color: broadcasting
                ? const Color(0xffffc66d)
                : const Color(0xff6d7480),
          ),
        ),
      ],
    ],
  );

  Widget _paneTitle(String text, bool broadcasting) {
    final data = widget.paneDragData;
    if (data == null) {
      return Expanded(child: _titleContent(text, broadcasting));
    }
    return Expanded(
      child: Draggable<String>(
        data: data,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(6),
          color: Theme.of(context).colorScheme.inverseSurface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.terminal, size: 14),
                const SizedBox(width: 6),
                Text(
                  widget.session.title,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onInverseSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
        child: Tooltip(
          message: '拖动窗格到其他窗格边缘可重新分屏；拖动分隔条可调整大小',
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: SizedBox(
              height: 32,
              child: _titleContent(text, broadcasting),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 520;
      final broadcasting = widget.broadcastScope != BroadcastScope.off;
      final targets = widget.broadcastTargetCount;
      return Row(
        children: [
          Icon(
            ended ? Icons.circle_outlined : Icons.circle,
            color: ended ? Colors.grey : const Color(0xff71cba2),
            size: 8,
          ),
          const SizedBox(width: 8),
          _paneTitle(
            '${ended ? '已断开 · ' : ''}${widget.session.title}'
            '${broadcasting ? ' · 广播 $targets' : ''}',
            broadcasting,
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
          if (widget.onSplitBack != null)
            IconButton(
              tooltip: '拆分分屏（移到新标签）',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              onPressed: widget.onSplitBack,
              icon: const Icon(
                Icons.close_fullscreen,
                color: Color(0xffa5adba),
                size: 16,
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
              const PopupMenuItem(
                value: 'shell-integration',
                child: Text('目录上报（文件跟随）'),
              ),
              const PopupMenuItem(
                value: 'command-finished-hook',
                child: Text('命令完成通知钩子'),
              ),
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
    _selectionMenuTimer?.cancel();
    _selectionMenuOverlay?.remove();
    _highlightTimer?.cancel();
    _shellProbeTimer?.cancel();
    _statusTimer?.cancel();
    _infoTimer?.cancel();
    _cursorTimer?.cancel();
    compose.dispose();
    controller.removeListener(_selectionForCopy);
    controller.removeListener(_selectionForMenu);
    pluginSettings.removeListener(_pluginSettingsChanged);
    keywordHighlights.removeListener(_highlightSettingsChanged);
    focus.removeListener(_imeFocusChanged);
    widget.session.removeInputListener(_inputObserved);
    widget.session.terminal.removeListener(_markLinksDirty);
    _linkRepaint.dispose();
    if (pluginSettings.imeAutoEnglish) {
      unawaited(
        _imeChannel
            .invokeMethod<void>('setAsciiInput', false)
            .catchError((Object _) {}),
      );
    }
    for (final highlight in List.of(controller.highlights)) {
      highlight.dispose();
    }
    focus.dispose();
    controller.dispose();
    super.dispose();
  }

  Widget _pinnedDock(List<PinnedCommand> pins) => Container(
    width: 56,
    decoration: BoxDecoration(
      color: const Color(0xff161c24),
      border: Border(
        left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final pin in pins)
          Tooltip(
            message: pin.name,
            child: InkWell(
              onTap: ended
                  ? null
                  : () {
                      _sendInput('${pin.command}\n');
                      _focus();
                    },
              onLongPress: () async {
                final remove = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('移除固定命令？'),
                    content: Text('${pin.name}\n${pin.command}'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('移除'),
                      ),
                    ],
                  ),
                );
                if (remove == true) await pinnedCommands.unpin(pin);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  children: [
                    Icon(
                      Icons.bolt,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pin.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 9),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

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
          if (pluginSettings.showSessionInfo ||
              (pluginSettings.showMachineInfo && !widget.session.isLocal))
            _infoBar(),
          if (pluginSettings.showStatusBar &&
              (_latencyMs != null ||
                  _cpuPercent != null ||
                  _memoryPercent != null))
            _statusBar(),
          Expanded(
            child: ListenableBuilder(
              listenable: pinnedCommands,
              builder: (context, _) {
                final pins = pinnedCommands.forHost(
                  widget.session.hostId,
                  tags: widget.hostTags,
                );
                final dock =
                    MediaQuery.sizeOf(context).width >= 1200 && pins.isNotEmpty;
                return Stack(
                  children: [
                    Positioned.fill(
                      right: dock ? 56 : 0,
                      child: ColoredBox(
                        color: terminalAppearance.activeTheme.background,
                        child: RepaintBoundary(
                          key: _terminalBoundary,
                          child: MouseRegion(
                            onHover: _hoverPath,
                            onExit: (_) => _clearHoverPath(),
                            child: Listener(
                            onPointerUp: _openLinkAt,
                            child: NotificationListener<ScrollNotification>(
                              onNotification: (_) {
                                _linkRepaint.value++;
                                return false;
                              },
                              child: Stack(
                                children: [
                                  TerminalView(
                                    key: _terminalViewKey,
                                    padding: EdgeInsets.fromLTRB(
                                      12,
                                      12,
                                      12,
                                      12 +
                                          terminalAppearance.bottomPadding
                                              .toDouble(),
                                    ),
                                    cursorType: switch (terminalAppearance
                                        .cursorStyle) {
                                      'underline' =>
                                        TerminalCursorType.underline,
                                      'verticalBar' =>
                                        TerminalCursorType.verticalBar,
                                      _ => TerminalCursorType.block,
                                    },
                                    deleteDetection:
                                        Theme.of(context).platform ==
                                            TargetPlatform.iOS ||
                                        Theme.of(context).platform ==
                                            TargetPlatform.android,
                                    widget.session.terminal,
                                    theme: terminalAppearance.activeTheme,
                                    controller: controller,
                                    focusNode: focus,
                                    onKeyEvent: (_, event) {
                                      if (event is KeyDownEvent &&
                                          widget.onShortcut != null) {
                                        final keyboard =
                                            HardwareKeyboard.instance;
                                        final apple =
                                            Theme.of(context).platform ==
                                                TargetPlatform.macOS ||
                                            Theme.of(context).platform ==
                                                TargetPlatform.iOS;
                                        final primary = apple
                                            ? keyboard.isMetaPressed
                                            : keyboard.isControlPressed &&
                                                  keyboard.isShiftPressed;
                                        if (event.logicalKey ==
                                            LogicalKeyboardKey.f11) {
                                          widget.onShortcut!('focus', null);
                                          return KeyEventResult.handled;
                                        }
                                        final customAction =
                                            shortcutSettings.match(
                                              keyId:
                                                  event.logicalKey.keyId,
                                              metaPressed:
                                                  keyboard.isMetaPressed,
                                              controlPressed:
                                                  keyboard.isControlPressed,
                                              shiftPressed:
                                                  keyboard.isShiftPressed,
                                              altPressed:
                                                  keyboard.isAltPressed,
                                            );
                                        if (customAction != null) {
                                          if (customAction == 'search') {
                                            unawaited(searchHistory());
                                          } else if (customAction ==
                                              'snippets') {
                                            unawaited(openSnippets());
                                          } else if (customAction ==
                                              'files') {
                                            widget.onOpenFiles?.call();
                                          } else if (customAction ==
                                              'clear') {
                                            widget.session.terminal
                                                .eraseDisplay();
                                            widget.session.terminal
                                                .eraseScrollbackOnly();
                                          } else if (customAction ==
                                              'zoom-in') {
                                            unawaited(_zoom(1));
                                          } else if (customAction ==
                                              'zoom-out') {
                                            unawaited(_zoom(-1));
                                          } else if (customAction ==
                                              'zoom-reset') {
                                            unawaited(_zoom(0));
                                          } else {
                                            widget.onShortcut!(
                                              customAction,
                                              null,
                                            );
                                          }
                                          return KeyEventResult.handled;
                                        }
                                        if (primary) {
                                          final key = event.logicalKey;
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
                                            widget.onShortcut!('favorite', index);
                                            return KeyEventResult.handled;
                                          }
                                        }
                                      }
                                      if (event is KeyDownEvent &&
                                          HardwareKeyboard
                                              .instance
                                              .isMetaPressed) {
                                        if (event.logicalKey ==
                                            LogicalKeyboardKey.keyV) {
                                          unawaited(paste());
                                          return KeyEventResult.handled;
                                        }
                                        if (event.logicalKey ==
                                            LogicalKeyboardKey.keyC) {
                                          unawaited(copy());
                                          return KeyEventResult.handled;
                                        }
                                      }
                                      return KeyEventResult.ignored;
                                    },
                                    autofocus: false,
                                    readOnly: ended,
                                    hardwareKeyboardOnly:
                                        Theme.of(context).platform ==
                                            TargetPlatform.windows &&
                                        pluginSettings.windowsHardwareInput,
                                    cursorVisible:
                                        _cursorVisible ||
                                        !terminalAppearance.cursorBlink,
                                    textStyle: TerminalStyle(
                                      fontSize: terminalAppearance.fontSize
                                          .toDouble(),
                                      height: terminalAppearance.lineHeight,
                                      fontWeight:
                                          terminalAppearance.terminalFontWeight,
                                      fontFamily: _terminalFontFamily,
                                      fontFamilyFallback: _terminalFontFallback,
                                    ),
                                    onSecondaryTapDown: (details, _) async {
                                      _dismissSelectionMenu();
                                      if (pluginSettings.rightClickPaste) {
                                        await paste();
                                        return;
                                      }
                                      final selection = controller.selection;
                                      final selectedTerminalText =
                                          selection == null
                                          ? ''
                                          : widget.session.terminal.buffer
                                                .getText(selection)
                                                .trim();
                                      final canFormatJson =
                                          pluginSettings.jsonFormatter &&
                                          isJsonText(selectedTerminalText);
                                      final canLookupIp =
                                          pluginSettings.ipLookup &&
                                          isIpv4(selectedTerminalText);
                                      _contextMenuOpen = true;
                                      final selected = await showMenu<String>(
                                        context: context,
                                        position: RelativeRect.fromLTRB(
                                          details.globalPosition.dx,
                                          details.globalPosition.dy,
                                          details.globalPosition.dx,
                                          details.globalPosition.dy,
                                        ),
                                        items: [
                                          const PopupMenuItem(
                                            value: 'copy',
                                            child: Text('复制'),
                                          ),
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
                                          if (canFormatJson)
                                            const PopupMenuItem(
                                              value: 'json',
                                              child: Text('格式化选中 JSON'),
                                            ),
                                          if (canLookupIp)
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
                                          if (pluginSettings.selectionPin)
                                            const PopupMenuItem(
                                              value: 'pin',
                                              child: Text('固定选中命令'),
                                            ),
                                          if (widget.snippets != null &&
                                              pluginSettings.selectionSnippet)
                                            const PopupMenuItem(
                                              value: 'save-snippet',
                                              child: Text('存为命令片段'),
                                            ),
                                          if (pluginSettings.selectionShare) ...[
                                            const PopupMenuItem(
                                              value: 'share-image',
                                              child: Text('快速分享终端图片'),
                                            ),
                                            const PopupMenuItem(
                                              value: 'share-image-templates',
                                              child: Text('分享为图片（模板）'),
                                            ),
                                          ],
                                          const PopupMenuItem(
                                            value: 'plugins',
                                            child: Text('插件设置'),
                                          ),
                                        ],
                                      );
                                      _contextMenuOpen = false;
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
                                      } else if (selected == 'share-image-templates') {
                                        await shareImageTemplates();
                                      } else if (selected == 'plugins') {
                                        if (!context.mounted) return;
                                        await showDialog<void>(
                                          context: context,
                                          builder: (_) =>
                                              const PluginSettingsDialog(),
                                        );
                                      }
                                    },
                                  ),
                                  if (pluginSettings.linkUnderline)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          key: const ValueKey(
                                            'terminal-link-underlines',
                                          ),
                                          painter: _LinkUnderlinePainter(
                                            terminal: widget.session.terminal,
                                            render: () => _terminalViewKey
                                                .currentState
                                                ?.renderTerminal,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            hoverLine: _hoverPathLine,
                                            hoverStart: _hoverPathStart,
                                            hoverEnd: _hoverPathEnd,
                                            repaint: _linkRepaint,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ),
                    if (dock)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        child: _pinnedDock(pins),
                      ),
                  ],
                );
              },
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
              final pins = pinnedCommands.forHost(
                widget.session.hostId,
                tags: widget.hostTags,
              );
              final dock =
                  MediaQuery.sizeOf(context).width >= 1200 && pins.isNotEmpty;
              if (pins.isEmpty || dock) return const SizedBox.shrink();
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
          if (pluginSettings.showComposeBar && !ended)
            Container(
              key: const ValueKey('terminal-compose-bar'),
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: compose,
                      minLines: 1,
                      maxLines: 3,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '撰写命令，发送到当前输入目标',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: '发送撰写内容',
                    onPressed: _sendCompose,
                    icon: const Icon(Icons.send, size: 18),
                  ),
                ],
              ),
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

class _LinkUnderlinePainter extends CustomPainter {
  final Terminal terminal;
  final Object? Function() render;
  final Color color;
  final int hoverLine, hoverStart, hoverEnd;
  _LinkUnderlinePainter({
    required this.terminal,
    required this.render,
    required this.color,
    required this.hoverLine,
    required this.hoverStart,
    required this.hoverEnd,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || terminal.isUsingAltBuffer) return;
    dynamic target;
    try {
      target = render();
    } catch (_) {
      return;
    }
    if (target == null) return;
    try {
      final cell = target.cellSize as Size;
      final lineHeight = (target.lineHeight as num).toDouble();
      if (cell.width <= 0 || lineHeight <= 0) return;
      final lines = terminal.buffer.lines;
      if (lines.length == 0) return;
      final top = target.getCellOffset(Offset.zero);
      final first = (top.y as int).clamp(0, lines.length - 1);
      final rows = (size.height / lineHeight).ceil() + 2;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      for (
        var line = first;
        line < first + rows && line < lines.length;
        line++
      ) {
        for (final span in findLinkSpans(lines[line].getText())) {
          if (span.start >= terminal.viewWidth) continue;
          final start =
              target.getOffset(CellOffset(span.start, line)) as Offset;
          final end = target.getOffset(
            CellOffset(span.end.clamp(0, terminal.viewWidth), line),
          ) as Offset;
          if (start.dy < -lineHeight || start.dy > size.height) continue;
          final y = start.dy + lineHeight - 1.5;
          canvas.drawLine(Offset(start.dx, y), Offset(end.dx, y), paint);
        }
        if (line == hoverLine && hoverStart >= 0 && hoverEnd > hoverStart) {
          final start =
              target.getOffset(CellOffset(hoverStart, line)) as Offset;
          final end = target.getOffset(
            CellOffset(hoverEnd.clamp(0, terminal.viewWidth), line),
          ) as Offset;
          final y = start.dy + lineHeight - 1.5;
          canvas.drawLine(Offset(start.dx, y), Offset(end.dx, y), paint);
        }
      }
    } catch (_) {
      // The render object can be between layouts; skip this frame.
    }
  }

  @override
  bool shouldRepaint(covariant _LinkUnderlinePainter oldDelegate) =>
      oldDelegate.terminal != terminal ||
      oldDelegate.color != color ||
      oldDelegate.hoverLine != hoverLine ||
      oldDelegate.hoverStart != hoverStart ||
      oldDelegate.hoverEnd != hoverEnd ||
      oldDelegate.render != render;
}
