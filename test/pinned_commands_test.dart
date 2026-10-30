import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/pinned_commands.dart';

void main() {
  test('pinned commands persist, deduplicate and filter by host', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-pins-');
    final file = File('${dir.path}/pins.json');
    try {
      final store = PinnedCommands(file: () async => file);
      await store.load();
      const all = PinnedCommand(name: 'uptime', command: 'uptime');
      const host = PinnedCommand(
        name: 'logs',
        command: 'tail -n 50 app.log',
        hostId: 'host-a',
      );
      await store.pin(all);
      await store.pin(all);
      await store.pin(host);
      expect(store.entries.length, 2);
      expect(store.forHost('host-b').map((e) => e.name), ['uptime']);
      expect(store.forHost('host-a').map((e) => e.name), ['logs', 'uptime']);

      final restored = PinnedCommands(file: () async => file);
      await restored.load();
      expect(restored.entries.length, 2);
      await restored.unpin(all);
      expect(restored.forHost('host-b'), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
