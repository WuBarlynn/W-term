import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/src/rust/frb_generated.dart';
import 'package:wterm/src/rust/api/client.dart' as client;
import 'package:wterm/src/rust/api/vault.dart' as vault;
import 'package:wterm/app/vault_store.dart';

void main() {
  test(
    'real bridge routes a terminal through a jump host and owns the chain',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          const String.fromEnvironment('WTERM_NATIVE_LIB'),
        ),
      );
      const sshPort = int.fromEnvironment('WTERM_TEST_PORT');
      const jumpPort = int.fromEnvironment('WTERM_JUMP_PORT');
      const jump2Port = int.fromEnvironment('WTERM_JUMP2_PORT');
      const stallPort = int.fromEnvironment('WTERM_STALL_PORT');
      expect(sshPort, greaterThan(0));
      expect(jumpPort, greaterThan(0));
      expect(jump2Port, greaterThan(0));
      expect(stallPort, greaterThan(0));
      final dir = await Directory.systemTemp.createTemp('wterm-route-bridge-');
      String? token, hop, hop2, target;
      StreamSubscription<List<int>>? output;
      try {
        final opened = await vault.vaultOpen(
          path: '${dir.path}/vault.db',
          password: 'route bridge vault password',
          create: true,
        );
        token = opened.token;
        final session = NativeVaultSession(token, false);

        // Cancel an in-flight handshake before any connection id exists.
        final stalled = session.probeWithProxy(
          '127.0.0.1',
          stallPort,
          operationId: 'stall-attempt',
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await session.cancelProbe('stall-attempt');
        await expectLater(
          stalled.timeout(const Duration(seconds: 5)),
          throwsA(anything),
        );

        final first = await session.probeWithProxy(
          '127.0.0.1',
          sshPort,
          operationId: 'hop-one',
        );
        hop = first.connectionId;
        await client.authenticateJump(
          connectionId: hop,
          approvedFingerprint: first.fingerprint,
          username: 'wterm',
          password: 'wterm-test-only',
          privateKey: '',
          passphrase: '',
        );
        await expectLater(
          session.probeThrough(
            'missing-parent',
            '127.0.0.1',
            jumpPort,
            operationId: 'no-parent',
          ),
          throwsA(anything),
        );

        final second = await session.probeThrough(
          hop,
          '127.0.0.1',
          jumpPort,
          operationId: 'hop-two',
        );
        hop2 = second.connectionId;
        // Wrong credentials on an intermediate hop fail without affecting hop one.
        await expectLater(
          client.authenticateJump(
            connectionId: hop2,
            approvedFingerprint: second.fingerprint,
            username: 'wterm',
            password: 'wrong-password',
            privateKey: '',
            passphrase: '',
          ),
          throwsA(anything),
        );
        final secondRetry = await session.probeThrough(
          hop,
          '127.0.0.1',
          jumpPort,
          operationId: 'hop-two-retry',
        );
        hop2 = secondRetry.connectionId;
        await client.authenticateJump(
          connectionId: hop2,
          approvedFingerprint: secondRetry.fingerprint,
          username: 'wterm',
          password: 'wterm-test-only',
          privateKey: '',
          passphrase: '',
        );

        final third = await session.probeThrough(
          hop2,
          '127.0.0.1',
          jump2Port,
          operationId: 'hop-three',
        );
        target = third.connectionId;
        await client.authenticate(
          connectionId: target,
          approvedFingerprint: third.fingerprint,
          username: 'wterm',
          password: 'wterm-test-only',
          privateKey: '',
          passphrase: '',
        );
        final echoed = Completer<void>();
        var text = '';
        final current = target;
        output = client.terminalOutput(connectionId: target).listen((bytes) {
          text += String.fromCharCodes(bytes);
          unawaited(client.acknowledgeOutput(connectionId: current));
          if (text.contains('WTERM_FIXTURE_READY:JUMP2') &&
              text.contains('ECHO:route-bridge')) {
            echoed.complete();
          }
        });
        await client.writeTerminal(
          connectionId: target,
          bytes: 'route-bridge\n'.codeUnits,
        );
        await echoed.future.timeout(const Duration(seconds: 10));

        // Closing the first jump must also tear down both later hops.
        await client.disconnect(connectionId: hop);
        hop = null;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await expectLater(
          client.writeTerminal(connectionId: hop2, bytes: [0x0a]),
          throwsA(anything),
        );
        await expectLater(
          client.writeTerminal(connectionId: target, bytes: [0x0a]),
          throwsA(anything),
        );
        hop2 = null;
        target = null;
        await output.cancel();
        output = null;

        await session.lock();
        await expectLater(
          session.probeThrough(
            'any',
            '127.0.0.1',
            jumpPort,
            operationId: 'locked',
          ),
          throwsA(anything),
        );
      } finally {
        if (hop != null) await client.disconnect(connectionId: hop);
        if (hop2 != null) await client.disconnect(connectionId: hop2);
        if (target != null) await client.disconnect(connectionId: target);
        await output?.cancel();
        if (token != null) await vault.vaultLock(token: token);
        await dir.delete(recursive: true);
        RustLib.dispose();
      }
    },
  );
}
