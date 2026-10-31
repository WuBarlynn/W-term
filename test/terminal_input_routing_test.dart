import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/terminal_session.dart';

class RoutingSession extends TerminalSession {
  RoutingSession()
    : super.offline(host: 'example.com', username: 'alice', onEnded: () {});
  final inputs = <String>[];
  final sent = <String>[];

  @override
  void sendInput(String text, {bool record = true}) => inputs.add(text);

  @override
  void send(String text, {bool record = true}) => sent.add(text);
}

void main() {
  test('terminal input is routed through the session, not a pane', () {
    final session = RoutingSession();
    session.terminal.textInput('ls -la\r');
    expect(session.inputs, ['ls -la\r']);
    // The route survives pane disposal because nothing in the widget tree
    // replaces terminal.onOutput.
    expect(session.terminal.onOutput, isNotNull);
  });

  test('terminal protocol replies are never broadcast as user input', () {
    final session = RoutingSession();
    session.terminal.write('\x1b[c');
    expect(session.inputs, isEmpty);
    expect(session.sent, isNotEmpty);
    session.terminal.textInput('echo hi');
    expect(session.inputs, ['echo hi']);
  });
}
