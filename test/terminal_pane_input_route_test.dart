import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
