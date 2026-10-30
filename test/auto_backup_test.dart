import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/auto_backup.dart';
import 'package:wterm/app/identity_store.dart';

class _FakeVault implements VaultMaintenance {
  int exports = 0, restores = 0;
  String? lastKey, lastPath;

  @override
  Future<void> changePassword(String current, String next) async {}

  @override
  Future<void> exportBackup(String path, String password) async {
    exports++;
    lastPath = path;
    lastKey = password;
    await File(path).writeAsString('encrypted');
  }

  @override
  Future<int> restoreBackup(String path, String password) async {
    restores++;
    lastPath = path;
    lastKey = password;
    return 3;
  }
}

void main() {
  test('automatic backups rotate and respect the daily interval', () async {
    final directory = await Directory.systemTemp.createTemp('wterm-backup-');
    try {
      final store = _FakeVault();
      String? key;
      final service = AutoBackupService(
        directory: () async => directory,
        keyReader: () async => key,
        keyWriter: (value) async => key = value,
      );
      final first = await service.ensureRecent(store);
      expect(first, isNotNull);
      expect(await first!.readAsString(), 'encrypted');
      expect(store.exports, 1);
      expect(key, isNotEmpty);
      expect(await service.ensureRecent(store), isNull);
      expect(await service.ensureRecent(store, force: true), isNotNull);
      expect(store.exports, 2);

      for (var index = 0; index < 6; index++) {
        await File(
          '${directory.path}/auto-2020010${index + 1}-000000.wterm-backup',
        ).writeAsString('old');
      }
      await service.ensureRecent(store, force: true);
      expect((await service.list()).length, lessThanOrEqualTo(5));

      final restored = await service.restore(first, store);
      expect(restored, 3);
      expect(store.restores, 1);
      expect(store.lastKey, key);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('restore refuses when the local backup key is absent', () async {
    final directory = await Directory.systemTemp.createTemp('wterm-backup-');
    try {
      final file = File('${directory.path}/auto-20200101-000000.wterm-backup');
      await file.writeAsString('encrypted');
      final service = AutoBackupService(
        directory: () async => directory,
        keyReader: () async => null,
        keyWriter: (_) async {},
      );
      await expectLater(
        service.restore(file, _FakeVault()),
        throwsA(isA<StateError>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
