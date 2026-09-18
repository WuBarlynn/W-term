import 'dart:io';

import 'package:wterm/app/quick_unlock.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/src/rust/frb_generated.dart';
import 'package:wterm/src/rust/api/vault.dart' as native;
import 'package:wterm/app/vault_store.dart';
import 'package:wterm/app/host_store.dart';
import 'package:wterm/app/identity_store.dart';

class NoQuickUnlock extends QuickUnlock {
  @override
  Future<bool> enabled() async => false;
}

void main() {
  test('real Dart bridge persists and locks SQLCipher vault', () async {
    const library = String.fromEnvironment('WTERM_NATIVE_LIB');
    expect(library, isNotEmpty, reason: 'Run scripts/test-vault-bridge.sh');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    final dir = await Directory.systemTemp.createTemp('wterm-vault-bridge-');
    final path = '${dir.path}/vault.db';
    NativeVaultSession? session;
    try {
      final opened = await native.vaultOpen(
        path: path,
        password: 'bridge fixture password',
        create: true,
      );
      session = NativeVaultSession(
        opened.token,
        opened.legacyImported,
        quickUnlock: NoQuickUnlock(),
      );
      await session.importLegacy(
        [
          HostProfile(
            id: 'smoke',
            name: 'Smoke host',
            host: 'localhost',
            username: 'fixture',
          ),
        ],
        ['Tests'],
      );
      expect((await session.read()).single.name, 'Smoke host');
      await session.writeFolders(['Updated']);
      final saved = await session.saveHost(
        HostProfile(
          id: 'saved',
          name: 'Saved login',
          host: 'localhost',
          username: 'fixture',
          group: 'Updated/Sub',
        ),
        IdentityDraft(
          name: 'Fixture identity',
          username: 'fixture',
          kind: 'password',
          password: 'synthetic secret',
        ),
      );
      expect(saved.identityId, isNotEmpty);
      expect((await session.identities()).single.username, 'fixture');
      await session.deleteFolder('Updated');
      expect(
        (await session.read()).firstWhere((h) => h.id == 'saved').group,
        '',
      );
      await session.writeFolders(['Updated']);
      await session.exportBackup(
        '${dir.path}/backup.db',
        'fixture backup password',
      );
      expect(
        await session.restoreBackup(
          '${dir.path}/backup.db',
          'fixture backup password',
        ),
        2,
      );
      expect((await session.identities()).length, 2);
      await session.changePassword(
        'bridge fixture password',
        'changed fixture password',
      );
      await session.lock();
      await expectLater(session.read(), throwsA(anything));
      await expectLater(
        native.vaultOpen(path: path, password: 'wrong', create: false),
        throwsA(anything),
      );
      final next = await native.vaultOpen(
        path: path,
        password: 'changed fixture password',
        create: false,
      );
      session = NativeVaultSession(
        next.token,
        next.legacyImported,
        quickUnlock: NoQuickUnlock(),
      );
      expect(next.legacyImported, isTrue);
      expect(await session.readFolders(), ['Updated']);
      expect((await session.read()).length, 4);
      expect(
        (await session.read()).firstWhere((h) => h.id == 'smoke').host,
        'localhost',
      );
      await session.saveHost(
        HostProfile(
          id: 'delete-child',
          name: 'Child',
          host: 'localhost',
          username: 'fixture',
          group: 'Delete/Sub',
        ),
        null,
      );
      await session.saveHost(
        HostProfile(
          id: 'keep-neighbor',
          name: 'Neighbor',
          host: 'localhost',
          username: 'fixture',
          group: 'Delete2',
        ),
        null,
      );
      await session.writeFolders(['Delete', 'Delete/Sub', 'Delete2']);
      await session.deleteFolder('Delete', deleteHosts: true);
      expect(
        (await session.read()).any((h) => h.id == 'delete-child'),
        isFalse,
      );
      expect(
        (await session.read()).any((h) => h.id == 'keep-neighbor'),
        isTrue,
      );
      expect(await session.readFolders(), ['Delete2']);
      expect((await session.identities()).length, 2);
    } finally {
      await session?.lock();
      await dir.delete(recursive: true);
      RustLib.dispose();
    }
  });
}
