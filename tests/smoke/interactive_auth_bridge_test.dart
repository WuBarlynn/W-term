import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/src/rust/frb_generated.dart';
import 'package:wterm/src/rust/api/client.dart' as client;
import 'package:wterm/src/rust/api/vault.dart' as vault;
import 'package:wterm/app/interactive_auth.dart';

void main() {
  test('real bridge completes multiple interactive rounds on the same SSH transport', () async {
    const library = String.fromEnvironment('WTERM_NATIVE_LIB');
    const port = int.fromEnvironment('WTERM_TEST_PORT');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    String? id;
    try {
      final p = await client.probeServer(host: '127.0.0.1', port: port);
      id = p.connectionId;
      var rounds = 0;
      String? previous;
      final user = await runInteractiveAuthentication(
        authenticate: () async {
          await client.authenticate(
            connectionId: id!,
            approvedFingerprint: p.fingerprint,
            username: 'mfa',
            password: '',
            privateKey: '',
            passphrase: '',
          );
          return 'mfa';
        },
        poll: () => client.authChallenge(connectionId: id!),
        reply: (challengeId, answers) => client.answerAuthChallenge(
          connectionId: id!,
          challengeId: challengeId,
          answers: answers,
        ),
        cancel: () => client.disconnect(connectionId: id!),
        ask: (c, finished) async {
          rounds++;
          expect(c.id, isNot(previous));
          previous = c.id;
          if (rounds == 1) {
            expect(c.prompts.length, 2);
            expect(c.prompts.first.echo, isFalse);
            expect(c.prompts.last.echo, isTrue);
            return ['654321', 'visible'];
          }
          expect(c.prompts, isEmpty);
          return [];
        },
      ).timeout(const Duration(seconds: 10));
      expect(user, 'mfa');
      expect(rounds, 2);
      expect(await client.authChallenge(connectionId: id), isNull);
      await expectLater(
        client.answerAuthChallenge(
          connectionId: id,
          challengeId: previous!,
          answers: [],
        ),
        throwsA(anything),
      );
      final files = await client.listDirectory(connectionId: id, path: '.');
      expect(files.entries.any((e) => e.name == 'fixture.txt'), isTrue);
    } finally {
      if (id != null) await client.disconnect(connectionId: id);
      RustLib.dispose();
    }
  });
  test(
    'saved interactive identity authenticates without stored secrets',
    () async {
      const library = String.fromEnvironment('WTERM_NATIVE_LIB');
      const port = int.fromEnvironment('WTERM_TEST_PORT');
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final dir = await Directory.systemTemp.createTemp('wterm-mfa-identity-');
      String? token, id;
      try {
        final opened = await vault.vaultOpen(
          path: '${dir.path}/vault.db',
          password: 'interactive bridge vault password',
          create: true,
        );
        token = opened.token;
        await vault.vaultImportLegacy(
          token: token,
          hostsJson: '[]',
          foldersJson: '[]',
        );
        final identityId = await vault.vaultSaveIdentity(
          token: token,
          input: const vault.IdentityInput(
            id: '',
            name: 'Saved MFA',
            username: 'mfa',
            kind: 'interactive',
            password: '',
            privateKey: '',
            passphrase: '',
            replaceSecret: true,
          ),
        );
        final p = await client.probeServer(host: '127.0.0.1', port: port);
        id = p.connectionId;
        var rounds = 0;
        final current = id;
        final user = await runInteractiveAuthentication(
          authenticate: () => vault.vaultAuthenticateIdentity(
            token: token!,
            identityId: identityId,
            connectionId: current,
            approvedFingerprint: p.fingerprint,
          ),
          poll: () => client.authChallenge(connectionId: current),
          reply: (challengeId, answers) => client.answerAuthChallenge(
            connectionId: current,
            challengeId: challengeId,
            answers: answers,
          ),
          cancel: () => client.disconnect(connectionId: current),
          ask: (challenge, finished) async {
            rounds++;
            return rounds == 1 ? ['654321', 'visible'] : <String>[];
          },
        ).timeout(const Duration(seconds: 10));
        expect(user, 'mfa');
        expect(rounds, 2);
        final files = await client.listDirectory(
          connectionId: current,
          path: '.',
        );
        expect(files.entries.any((e) => e.name == 'fixture.txt'), isTrue);
        await client.disconnect(connectionId: current);
        id = null;
        await vault.vaultLock(token: token);
        final lockedProbe = await client.probeServer(
          host: '127.0.0.1',
          port: port,
        );
        id = lockedProbe.connectionId;
        await expectLater(
          vault.vaultAuthenticateIdentity(
            token: token,
            identityId: identityId,
            connectionId: lockedProbe.connectionId,
            approvedFingerprint: lockedProbe.fingerprint,
          ),
          throwsA(anything),
        );
        await client.disconnect(connectionId: id);
        id = null;
      } finally {
        if (id != null) await client.disconnect(connectionId: id);
        if (token != null) await vault.vaultLock(token: token);
        await dir.delete(recursive: true);
        RustLib.dispose();
      }
    },
  );
}
