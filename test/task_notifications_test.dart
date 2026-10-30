import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/task_notifications.dart';

void main() {
  test('long commands complete after output becomes idle', () async {
    var now = DateTime(2026, 1, 1);
    final monitor = TaskMonitor(
      now: () => now,
      enabled: () => true,
      idleDelay: const Duration(milliseconds: 20),
      minimumDuration: const Duration(seconds: 5),
    );
    monitor.commandSubmitted(
      'session-1',
      'cargo build --release',
      title: 'deploy@example.com',
    );
    now = now.add(const Duration(seconds: 6));
    monitor.activity('session-1');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final completion = monitor.drain().single;
    expect(completion.command, 'cargo build --release');
    expect(completion.title, 'deploy@example.com');
    expect(completion.elapsed, const Duration(seconds: 6));
    expect(monitor.drain(), isEmpty);
  });

  test('short commands and interactive programs are ignored', () async {
    var now = DateTime(2026, 1, 1);
    final monitor = TaskMonitor(
      now: () => now,
      enabled: () => true,
      idleDelay: const Duration(milliseconds: 20),
      minimumDuration: const Duration(seconds: 5),
    );
    monitor.commandSubmitted('short', 'uptime', title: 'host');
    now = now.add(const Duration(seconds: 1));
    monitor.activity('short');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(monitor.drain(), isEmpty);
    monitor.commandSubmitted('editor', 'vim notes.txt', title: 'host');
    now = now.add(const Duration(seconds: 30));
    monitor.activity('editor');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(monitor.drain(), isEmpty);
    monitor.commandSubmitted('tail', 'tail -f app.log', title: 'host');
    monitor.activity('tail');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(monitor.drain(), isEmpty);
  });

  test(
    'disabled plugin, closed sessions and cancellation stay silent',
    () async {
      var now = DateTime(2026, 1, 1);
      final monitor = TaskMonitor(
        now: () => now,
        enabled: () => false,
        idleDelay: const Duration(milliseconds: 20),
        minimumDuration: const Duration(seconds: 5),
      );
      monitor.commandSubmitted('s', 'make', title: 'host');
      now = now.add(const Duration(seconds: 30));
      monitor.activity('s');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(monitor.drain(), isEmpty);

      final enabled = TaskMonitor(
        now: () => now,
        enabled: () => true,
        idleDelay: const Duration(milliseconds: 20),
        minimumDuration: const Duration(seconds: 5),
      );
      enabled.commandSubmitted('s', 'make', title: 'host');
      enabled.sessionClosed('s');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(enabled.drain(), isEmpty);
    },
  );
}
