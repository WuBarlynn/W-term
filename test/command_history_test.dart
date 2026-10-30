import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/command_history.dart';

void main() {
  test('tracker ignores control sequences and handles editing', () {
    final tracker = CommandLineTracker();
    expect(tracker.feed('ls -l'), isEmpty);
    expect(tracker.feed('\x1b[A'), isEmpty);
    expect(tracker.feed('\x7f'), isEmpty);
    expect(tracker.feed('\r'), ['ls -']);
    expect(tracker.feed('echo ok\n'), ['echo ok']);
    expect(tracker.feed('   \r'), isEmpty);
  });

  test('history records, reloads and clears bounded entries', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-history-');
    final file = File('${dir.path}/history.json');
    try {
      final history = CommandHistory(file: () async => file);
      await history.record(
        command: 'uptime',
        host: 'example.com',
        username: 'alice',
      );
      await history.record(
        command: 'df -h',
        host: 'example.com',
        username: 'alice',
      );
      final restored = CommandHistory(file: () async => file);
      await restored.load();
      expect(restored.entries.length, 2);
      expect(restored.entries.first.command, 'df -h');
      await restored.clear();
      final empty = CommandHistory(file: () async => file);
      await empty.load();
      expect(empty.entries, isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
