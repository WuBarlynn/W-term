import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/sync_automation.dart';

void main() {
  test('auto sync preference persists', () async {
    final directory = await Directory.systemTemp.createTemp('wterm-autosync-');
    final file = File('${directory.path}/sync.json');
    try {
      final settings = SyncAutomation(file: () async => file);
      await settings.load();
      expect(settings.enabled, isFalse);
      await settings.setEnabled(true);
      final restored = SyncAutomation(file: () async => file);
      await restored.load();
      expect(restored.enabled, isTrue);
      expect(restored.intervalMinutes, 15);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
