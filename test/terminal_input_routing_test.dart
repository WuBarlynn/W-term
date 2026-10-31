import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/terminal_session.dart';

class RoutingSession extends TerminalSession {
  RoutingSession()
    : super.offline(host: 'example.com', username: 'alice', onEnded: () {});
  final inputs = <String>[];

  @override
  void sendInput(String text, {bool record = true}) => inputs.add(text);
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
}
