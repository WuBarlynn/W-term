import '../app/snippet_store.dart';
import 'snippets_dialog.dart';
import 'terminal_search.dart';
import '../app/terminal_appearance.dart';
import 'terminal_appearance_dialog.dart';
import 'system_monitor_dialog.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../app/terminal_session.dart';
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
  bool _wasActive = false;
  @override
  void initState() {
    super.initState();
    terminalAppearance.addListener(appearanceChanged);
    widget.session.addListener(sessionChanged);
    widget.session.terminal.onOutput = _output;
    _wasActive = widget.active;
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus());
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

  Future<void> paneMenu(String value) async {
    if (value == 'reconnect') {
      widget.onReconnect?.call();
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
                const PopupMenuDivider(),
              ],
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
              color: TerminalAppearance.themeFor(terminalAppearance.palette)
                  .background,
              child: TerminalView(
                deleteDetection:
                    Theme.of(context).platform == TargetPlatform.iOS ||
                    Theme.of(context).platform == TargetPlatform.android,
                widget.session.terminal,
                theme: TerminalAppearance.themeFor(terminalAppearance.palette),
                controller: controller,
                focusNode: focus,
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent && widget.onShortcut != null) {
                    final keyboard = HardwareKeyboard.instance;
                    final apple =
                        Theme.of(context).platform == TargetPlatform.macOS ||
                        Theme.of(context).platform == TargetPlatform.iOS;
                    final primary = apple
                        ? keyboard.isMetaPressed
                        : keyboard.isControlPressed && keyboard.isShiftPressed;
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
                    items: const [
                      PopupMenuItem(value: 'copy', child: Text('复制')),
                      PopupMenuItem(value: 'paste', child: Text('粘贴')),
                    ],
                  );
                  if (selected == 'copy') {
                    await copy();
                  } else if (selected == 'paste') {
                    await paste();
                  }
                },
              ),
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
