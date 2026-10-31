import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/pinned_commands.dart';
import 'package:wterm/app/plugins.dart';
import 'package:wterm/app/terminal_session.dart';
import 'package:wterm/features/terminal_pane.dart';

class _RoutingSession extends TerminalSession {
  _RoutingSession()
    : super.offline(host: 'example.com', username: 'alice', onEnded: () {});
  final inputs = <String>[];

  @override
  void sendInput(String text, {bool record = true}) => inputs.add(text);
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
