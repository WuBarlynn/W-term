import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/terminal_session.dart';
import 'package:wterm/app/task_notifications.dart';

void main() {
  test('OSC 133;D reaches the command-finished callback', () {
    final exits = <int?>[];
    final session = TerminalSession.offline(
      host: 'example.com',
      username: 'alice',
      onEnded: () {},
    );
    session.onCommandFinished = exits.add;
    session.terminal.write('\x1b]133;D;7\x07');
    session.terminal.write('\x1b]133;D;0\x07');
    expect(exits, [7, 0]);
    session.terminal.write('\x1b]7;file://host/tmp/dir\x07');
    expect(session.currentDirectory, '/tmp/dir');
  });

  test('exact completion uses the finish marker and carries exit code', () {
    var now = DateTime(2026, 1, 1);
    final monitor = TaskMonitor(
      now: () => now,
      enabled: () => true,
      minimumDuration: const Duration(seconds: 5),
    );
    monitor.commandSubmitted('s', 'sleep 20', title: 'host');
    now = now.add(const Duration(seconds: 20));
    monitor.commandFinished('s', exitCode: 0);
    final completion = monitor.drain().single;
    expect(completion.exitCode, 0);
    expect(completion.elapsed, const Duration(seconds: 20));
  });
}
