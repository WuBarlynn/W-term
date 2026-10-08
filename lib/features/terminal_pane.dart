import '../app/snippet_store.dart';
import 'snippets_dialog.dart';
import '../app/errors.dart';
import 'terminal_search.dart';
import '../app/terminal_appearance.dart';
import 'terminal_appearance_dialog.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../src/rust/api/client.dart' as native;

class TerminalPane extends StatefulWidget {
  final String connectionId;
  final SnippetStore? snippets;
  final VoidCallback onDisconnected;
  const TerminalPane({
    super.key,
    required this.connectionId,
    this.snippets,
    required this.onDisconnected,
  });
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final terminal = Terminal(maxLines: 5000);
  final controller = TerminalController();
  final focus = FocusNode();
  final bytes = StreamController<List<int>>(sync: true);
  StreamSubscription? output, decoded;
  Future<void> writes = Future.value();
  bool ended = false;
  Timer? resizeTimer;
  @override
  void initState() {
    super.initState();
    terminalAppearance.addListener(appearanceChanged);
    // Decoder retains partial UTF-8 sequences across SSH packets.
    decoded = utf8.decoder
        .bind(bytes.stream)
        .listen(terminal.write, onError: (_) {});
    terminal.onOutput = send;
    terminal.onResize = (cols, rows, pw, ph) {
      resizeTimer?.cancel();
      resizeTimer = Timer(const Duration(milliseconds: 80), () {
        if (!ended) {
          unawaited(
            native
                .resizeTerminal(
                  connectionId: widget.connectionId,
                  columns: cols,
                  rows: rows,
                )
                .catchError((Object _) {}),
          );
        }
      });
    };
    output = native
        .terminalOutput(connectionId: widget.connectionId)
        .listen(
          (data) {
            bytes.add(data);
            unawaited(
              native
                  .acknowledgeOutput(connectionId: widget.connectionId)
                  .catchError((Object _) {}),
            );
          },
          onError: (Object error) {
            finish(userFacingError(error));
          },
          onDone: () => finish(null),
        );
  }

  void finish(String? error) {
    if (!mounted || ended) return;
    setState(() => ended = true);
    terminal.write(
      '\r\n\x1b[90m${error == null ? '连接已结束' : '连接中断：$error'}\x1b[0m\r\n',
    );
    widget.onDisconnected();
  }

  void send(String text) {
    if (ended) return;
    writes = writes
        .then(
          (_) => native.writeTerminal(
            connectionId: widget.connectionId,
            bytes: utf8.encode(text),
          ),
        )
        .catchError((Object error) {
          finish(userFacingError(error));
        });
  }

  void appearanceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> editAppearance() async {
    await showDialog<void>(
      context: context,
      builder: (_) => TerminalAppearanceDialog(store: terminalAppearance),
    );
    if (mounted) focus.requestFocus();
  }

  Future<void> searchHistory() async {
    await showDialog<void>(
      context: context,
      builder: (_) => TerminalSearch(
        snapshot: () {
          final lines = <String>[];
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
    if (mounted) focus.requestFocus();
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
    terminal.paste(command);
    focus.requestFocus();
  }

  Future<void> copy() async {
    final selection = controller.selection;
    if (selection != null) {
      await Clipboard.setData(
        ClipboardData(text: terminal.buffer.getText(selection)),
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
    terminal.paste(text);
    focus.requestFocus();
  }

  @override
  void dispose() {
    ended = true;
    terminalAppearance.removeListener(appearanceChanged);
    resizeTimer?.cancel();
    output?.cancel();
    decoded?.cancel();
    bytes.close();
    terminal.onOutput = null;
    terminal.onResize = null;
    focus.dispose();
    controller.dispose();
    unawaited(
      native
          .disconnect(connectionId: widget.connectionId)
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        color: const Color(0xff161c24),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(
              ended ? Icons.circle_outlined : Icons.circle,
              color: ended ? Colors.grey : const Color(0xff71cba2),
              size: 8,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ended ? '已断开' : 'SSH · xterm-256color',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xffa5adba), fontSize: 12),
              ),
            ),
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
        ),
      ),
      Expanded(
        child: ColoredBox(
          color: TerminalAppearance.themeFor(terminalAppearance.palette)
              .background,
          child: TerminalView(
            deleteDetection:
                Theme.of(context).platform == TargetPlatform.iOS ||
                Theme.of(context).platform == TargetPlatform.android,
            terminal,
            theme: TerminalAppearance.themeFor(terminalAppearance.palette),
            controller: controller,
            focusNode: focus,
            onKeyEvent: (_, event) {
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
            autofocus: true,
            readOnly: ended,
            padding: const EdgeInsets.all(12),
            textStyle: TerminalStyle(
              fontSize: terminalAppearance.fontSize.toDouble(),
              fontFamily: 'Menlo',
              fontFamilyFallback: ['monospace'],
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
                          send(key.$2);
                          focus.requestFocus();
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
  );
}
