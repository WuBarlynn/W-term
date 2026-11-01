import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/pinned_commands.dart';
import 'package:wterm/app/plugins.dart';
import 'package:wterm/app/terminal_session.dart';
import 'package:wterm/features/terminal_pane.dart';
import 'package:xterm/xterm.dart';

class _RoutingSession extends TerminalSession {
  _RoutingSession()
    : super.offline(host: 'example.com', username: 'alice', onEnded: () {});
  final inputs = <String>[];

  @override
  void sendInput(String text, {bool record = true}) => inputs.add(text);
}

class _LiveSession extends _RoutingSession {
  @override
  bool get ended => false;
}

void main() {
  testWidgets('disposing a pane keeps the session input route', (tester) async {
    final session = _RoutingSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(session: session, active: true, onActivate: () {}),
        ),
      ),
    );
    await tester.pump();
    session.terminal.textInput('a');
    expect(session.inputs, ['a']);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    session.terminal.textInput('b');
    expect(session.inputs, ['a', 'b']);
  });

  testWidgets('wide terminals show pinned commands in a right dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    pinnedCommands.entries.add(
      const PinnedCommand(name: 'dockcmd', command: 'uptime'),
    );
    addTearDown(pinnedCommands.entries.clear);
    final session = _RoutingSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(session: session, active: true, onActivate: () {}),
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('dockcmd'), findsOneWidget);
  });

  testWidgets('selecting terminal text opens the selection actions menu', (
    tester,
  ) async {
    final previous = (
      pluginSettings.selectionMenu,
      pluginSettings.jsonFormatter,
      pluginSettings.ipLookup,
      pluginSettings.selectionPin,
      pluginSettings.selectionSnippet,
      pluginSettings.selectionShare,
    );
    pluginSettings
      ..selectionMenu = true
      ..jsonFormatter = true
      ..ipLookup = true
      ..selectionPin = false
      ..selectionSnippet = false
      ..selectionShare = false;
    addTearDown(() {
      pluginSettings
        ..selectionMenu = previous.$1
        ..jsonFormatter = previous.$2
        ..ipLookup = previous.$3
        ..selectionPin = previous.$4
        ..selectionSnippet = previous.$5
        ..selectionShare = previous.$6;
    });
    final session = _LiveSession();
    session.terminal.write('{"a":1} 1.2.3.4\r\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(session: session, active: true, onActivate: () {}),
        ),
      ),
    );
    await tester.pump();
    final view = find.byType(TerminalView);
    expect(view, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    final controller = tester.widget<TerminalView>(view).controller!;
    final buffer = session.terminal.buffer;
    var line = -1;
    for (var index = 0; index < buffer.lines.length; index++) {
      if (buffer.lines[index].getText().contains('1.2.3.4')) {
        line = index;
        break;
      }
    }
    expect(line, greaterThanOrEqualTo(0));
    controller.setSelection(
      buffer.createAnchorFromOffset(CellOffset(0, line)),
      buffer.createAnchorFromOffset(CellOffset(8, line)),
    );
    expect(buffer.getText(controller.selection!).trim(), '{"a":1}');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.byTooltip('格式化选中 JSON'), findsOneWidget);
    expect(find.byTooltip('查询选中 IP 归属'), findsNothing);
    expect(find.byTooltip('固定选中命令'), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('link underlines render over terminal output', (tester) async {
    pluginSettings.linkUnderline = true;
    addTearDown(() => pluginSettings.linkUnderline = true);
    final session = _RoutingSession();
    session.terminal.write('https://example.com/docs\r\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(session: session, active: true, onActivate: () {}),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('terminal-link-underlines')),
      findsOneWidget,
    );
  });
}
