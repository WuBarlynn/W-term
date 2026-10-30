import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/src/rust/frb_generated.dart';
import 'package:wterm/src/rust/api/client.dart' as client;
import 'package:wterm/src/rust/api/proxy.dart';
import 'package:wterm/src/rust/api/vault.dart' as vault;
import 'package:wterm/app/vault_store.dart';

void main() {
  test('real vault bridge uses authenticated HTTP/SOCKS proxies and retains host key checks', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        const String.fromEnvironment('WTERM_NATIVE_LIB'),
      ),
    );
    const sshPort = int.fromEnvironment('WTERM_TEST_PORT');
    final dir = await Directory.systemTemp.createTemp('wterm-proxy-bridge-');
    String? token, id;
    StreamSubscription<List<int>>? output;
    try {
      final opened = await vault.vaultOpen(
        path: '${dir.path}/vault.db',
        password: 'fixture vault password',
        create: true,
      );
      token = opened.token;
      var session = NativeVaultSession(token, false);
      await vault.vaultImportLegacy(
        token: token,
        hostsJson: '[]',
        foldersJson: '[]',
      );
      await vault.vaultWrite(
        token: token,
        kind: 'hosts',
        json: jsonEncode([
          {
            'id': 'bound-host',
            'name': 'Bound',
            'host': '127.0.0.1',
            'username': 'wterm',
            'port': sshPort,
            'group': '',
            'tags': <String>[],
            'favorite': false,
          },
        ]),
      );
      expect((await session.proxySettings()).mode, 'direct');
      for (final entry in {
        'http': const int.fromEnvironment('WTERM_HTTP_PROXY_PORT'),
        'socks5': const int.fromEnvironment('WTERM_SOCKS_PROXY_PORT'),
      }.entries) {
        final settings = ProxySettings(
          mode: entry.key,
          host: '127.0.0.1',
          port: entry.value,
          authenticate: true,
          username: 'proxy-user',
          passwordSaved: false,
        );
        await session.saveProxySettings(settings, 'wrong-password');
        await expectLater(
          session.probeWithProxy('fixture.invalid', sshPort),
          throwsA(anything),
        );
        await session.saveProxySettings(settings, 'proxy-secret');
        expect((await session.proxySettings()).passwordSaved, isTrue);
        await session.saveProxySettings(settings, '');
        // Credentials and route survive a complete lock/open cycle.
        await session.lock();
        final reopened = await vault.vaultOpen(
          path: '${dir.path}/vault.db',
          password: 'fixture vault password',
          create: false,
        );
        token = reopened.token;
        session = NativeVaultSession(token, false);
        final refused = await session.probeWithProxy(
          'fixture.invalid',
          sshPort,
        );
        id = refused.connectionId;
        await expectLater(
          client.authenticate(
            connectionId: id,
            approvedFingerprint: 'wrong fingerprint',
            username: 'wterm',
            password: 'wterm-test-only',
            privateKey: '',
            passphrase: '',
          ),
          throwsA(anything),
        );
        await client.disconnect(connectionId: id);
        id = null;
        final identity = await session.probeWithProxy(
          'fixture.invalid',
          sshPort,
        );
        id = identity.connectionId;
        final currentId = id;
        await client.authenticate(
          connectionId: id,
          approvedFingerprint: identity.fingerprint,
          username: 'wterm',
          password: 'wterm-test-only',
          privateKey: '',
          passphrase: '',
        );
        final echoed = Completer<void>();
        var text = '';
        output = client.terminalOutput(connectionId: id).listen((bytes) {
          text += String.fromCharCodes(bytes);
          unawaited(client.acknowledgeOutput(connectionId: currentId));
          if (text.contains('ECHO:proxy-bridge') && !echoed.isCompleted) {
            echoed.complete();
          }
        });
        await client.writeTerminal(
          connectionId: id,
          bytes: 'proxy-bridge\n'.codeUnits,
        );
        await echoed.future.timeout(const Duration(seconds: 10));
        await client.disconnect(connectionId: id);
        id = null;
        await output.cancel();
        output = null;
      }
      final profileId = await session.saveProxyProfile(
        const ProxyProfileInput(
          id: '',
          name: 'Corp',
          mode: 'http',
          host: '127.0.0.1',
          port: int.fromEnvironment('WTERM_HTTP_PROXY_PORT'),
          authenticate: true,
          username: 'proxy-user',
        ),
        'proxy-secret',
      );
      expect((await session.proxyProfiles()).single.passwordSaved, isTrue);
      await session.setHostProxyBinding('bound-host', profileId);
      expect(await session.hostProxyBinding('bound-host'), profileId);
      await expectLater(
        session.deleteProxyProfile(profileId),
        throwsA(anything),
      );
      final layered = await session.testProxyProfile(
        profileId,
        'fixture.invalid',
        sshPort,
      );
      expect(layered.tcpOk, isTrue);
      expect(layered.authenticated, isTrue);
      expect(layered.targetOk, isTrue);
      final tcpOnly = await session.testProxyProfile(profileId, '', 0);
      expect(tcpOnly.tcpOk, isTrue);
      expect(tcpOnly.authenticated, isNull);
      expect(tcpOnly.targetOk, isNull);
      const draft = ProxyDraft(
        mode: 'http',
        host: '127.0.0.1',
        port: int.fromEnvironment('WTERM_HTTP_PROXY_PORT'),
        authenticate: true,
        username: 'proxy-user',
      );
      expect(
        (await session.testProxyDraft(
          draft,
          'proxy-secret',
          'fixture.invalid',
          sshPort,
        )).targetOk,
        isTrue,
      );
      expect(
        (await session.testProxyDraft(
          draft,
          'wrong-password',
          'fixture.invalid',
          sshPort,
        )).authenticated,
        isFalse,
      );
      final bound = await session.probeWithHostProxy(
        'bound-host',
        'fixture.invalid',
        sshPort,
        operationId: 'bound-host',
      );
      id = bound.connectionId;
      await client.authenticate(
        connectionId: id,
        approvedFingerprint: bound.fingerprint,
        username: 'wterm',
        password: 'wterm-test-only',
        privateKey: '',
        passphrase: '',
      );
      await client.disconnect(connectionId: id);
      id = null;
      await session.setHostProxyBinding('bound-host', 'direct');
      await expectLater(
        session.probeWithHostProxy('bound-host', 'fixture.invalid', sshPort),
        throwsA(anything),
      );
      await session.setHostProxyBinding('bound-host', '');
      await session.deleteProxyProfile(profileId);
      expect(await session.proxyProfiles(), isEmpty);
      await session.saveProxySettings(
        const ProxySettings(
          mode: 'direct',
          host: '',
          port: 1080,
          authenticate: false,
          username: '',
          passwordSaved: false,
        ),
        '',
      );
      expect((await session.proxySettings()).passwordSaved, isFalse);
      final direct = await session.probeWithProxy('127.0.0.1', sshPort);
      await client.disconnect(connectionId: direct.connectionId);
      await session.lock();
      await expectLater(
        session.probeWithProxy('127.0.0.1', sshPort),
        throwsA(anything),
      );
    } finally {
      if (id != null) await client.disconnect(connectionId: id);
      await output?.cancel();
      if (token != null) await vault.vaultLock(token: token);
      await dir.delete(recursive: true);
      RustLib.dispose();
    }
  });
}
