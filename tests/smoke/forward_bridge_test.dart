import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/src/rust/frb_generated.dart';
import 'package:wterm/src/rust/api/client.dart' as client;
import 'package:wterm/src/rust/api/forward.dart' as forward;
import 'package:wterm/src/rust/api/vault.dart' as vault;
import 'package:wterm/app/vault_store.dart';

Future<void> readExact(
  StreamIterator<List<int>> iterator,
  int count,
  List<int> output,
) async {
  while (output.length < count) {
    if (!await iterator.moveNext()) {
      throw StateError('stream closed before $count bytes');
    }
    output.addAll(iterator.current);
  }
}

Future<List<int>> exchangeTcp(int port, List<int> payload) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final received = socket.fold<List<int>>(
    [],
    (all, bytes) => all..addAll(bytes),
  );
  socket.add(payload);
  await socket.flush();
  await socket.close();
  return received.timeout(const Duration(seconds: 10));
}

void main() {
  test('real bridge tunnels bytes and releases listeners after shell exit', () async {
    const library = String.fromEnvironment('WTERM_NATIVE_LIB');
    const fixturePort = int.fromEnvironment('WTERM_TEST_PORT');
    expect(
      library,
      isNotEmpty,
      reason: 'Run WTERM_TEST_FORWARD_BRIDGE=1 scripts/test-core.sh',
    );
    expect(fixturePort, greaterThan(0));
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    String? id;
    ServerSocket? server;
    Socket? socket;
    final accepted = <Socket>[];
    StreamSubscription<Socket>? connections;
    StreamSubscription<List<int>>? terminal;
    try {
      final identity = await client.probeServer(
        host: '127.0.0.1',
        port: fixturePort,
      );
      id = identity.connectionId;
      await client.authenticate(
        connectionId: id,
        approvedFingerprint: identity.fingerprint,
        username: 'wterm',
        password: 'wterm-test-only',
        privateKey: '',
        passphrase: '',
      );
      terminal = client.terminalOutput(connectionId: id).listen((_) {
        unawaited(
          client.acknowledgeOutput(connectionId: identity.connectionId),
        );
      });
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      connections = server.listen((peer) {
        accepted.add(peer);
        peer.listen(
          peer.add,
          onDone: () async {
            await peer.flush();
            await peer.close();
          },
        );
      });
      final rule = await forward.startLocalForward(
        connectionId: id,
        localPort: 0,
        targetHost: '127.0.0.1',
        targetPort: server.port,
      );
      expect(await forward.listLocalForwards(connectionId: id), [rule]);
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        rule.localPort,
      );
      final payload = List.generate(65537, (index) => index % 251);
      final received = socket.fold<List<int>>(
        [],
        (all, bytes) => all..addAll(bytes),
      );
      socket.add(payload);
      await socket.flush();
      // Half-close must preserve the response flowing back through the tunnel.
      await socket.close();
      expect(await received.timeout(const Duration(seconds: 10)), payload);
      await forward.stopLocalForward(connectionId: id, forwardId: rule.id);
      expect(await forward.listLocalForwards(connectionId: id), isEmpty);
      final rebound = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        rule.localPort,
      );
      await rebound.close();
      final active = await forward.startLocalForward(
        connectionId: id,
        localPort: 0,
        targetHost: '127.0.0.1',
        targetPort: server.port,
      );
      await client.writeTerminal(connectionId: id, bytes: 'exit\n'.codeUnits);
      // A remote shell exit, not only the UI disconnect button, releases tunnels.
      await (() async {
        while (true) {
          try {
            final listener = await ServerSocket.bind(
              InternetAddress.loopbackIPv4,
              active.localPort,
            );
            await listener.close();
            return;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        }
      })().timeout(const Duration(seconds: 5));
      await expectLater(
        forward.startLocalForward(
          connectionId: id,
          localPort: 0,
          targetHost: '127.0.0.1',
          targetPort: server.port,
        ),
        throwsA(anything),
      );
    } finally {
      socket?.destroy();
      for (final peer in accepted) {
        peer.destroy();
      }
      await connections?.cancel();
      await server?.close();
      if (id != null) await client.disconnect(connectionId: id);
      await terminal?.cancel();
      RustLib.dispose();
    }
  });

  test('real bridge starts remote -R and dynamic -D forwards', () async {
    const library = String.fromEnvironment('WTERM_NATIVE_LIB');
    const fixturePort = int.fromEnvironment('WTERM_TEST_PORT');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    String? id;
    ServerSocket? echo;
    StreamSubscription<List<int>>? terminal;
    final peers = <Socket>[];
    try {
      final identity = await client.probeServer(
        host: '127.0.0.1',
        port: fixturePort,
      );
      id = identity.connectionId;
      await client.authenticate(
        connectionId: id,
        approvedFingerprint: identity.fingerprint,
        username: 'wterm',
        password: 'wterm-test-only',
        privateKey: '',
        passphrase: '',
      );
      terminal = client.terminalOutput(connectionId: id).listen((_) {
        unawaited(client.acknowledgeOutput(connectionId: id!));
      });
      echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((peer) {
        peers.add(peer);
        peer.listen(
          peer.add,
          onDone: () async {
            await peer.flush();
            await peer.close();
          },
        );
      });
      final payload = List.generate(1024, (index) => index % 251);
      final remote = await forward.startForward(
        connectionId: id,
        kind: 'remote',
        listenHost: '127.0.0.1',
        listenPort: 0,
        targetHost: '127.0.0.1',
        targetPort: echo.port,
      );
      expect(remote.listenRemote, isTrue);
      expect(await exchangeTcp(remote.listenPort, payload), payload);
      await forward.stopForward(connectionId: id, forwardId: remote.id);
      final dynamic = await forward.startForward(
        connectionId: id,
        kind: 'dynamic',
        listenHost: '127.0.0.1',
        listenPort: 0,
        targetHost: '',
        targetPort: 0,
      );
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        dynamic.listenPort,
      );
      try {
        final iterator = StreamIterator<List<int>>(socket);
        socket.add([5, 1, 0]);
        final greeting = <int>[];
        await readExact(iterator, 2, greeting);
        expect(greeting, [5, 0]);
        final port = echo.port;
        socket.add([5, 1, 0, 1, 127, 0, 0, 1, port >> 8, port & 0xff]);
        final reply = <int>[];
        await readExact(iterator, 10, reply);
        expect(reply[0], 5);
        expect(reply[1], 0);
        socket.add(payload);
        final echoed = <int>[];
        while (echoed.length < payload.length) {
          if (!await iterator.moveNext()) break;
          echoed.addAll(iterator.current);
        }
        expect(echoed, payload);
      } finally {
        socket.destroy();
      }
      await forward.stopForward(connectionId: id, forwardId: dynamic.id);
      expect(await forward.listForwards(connectionId: id), isEmpty);
    } finally {
      for (final peer in peers) {
        peer.destroy();
      }
      await echo?.close();
      if (id != null) await client.disconnect(connectionId: id);
      await terminal?.cancel();
      RustLib.dispose();
    }
  });

  test('saved forwarding rules round-trip through the vault', () async {
    const library = String.fromEnvironment('WTERM_NATIVE_LIB');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    final dir = await Directory.systemTemp.createTemp('wterm-forward-rules-');
    String? token;
    try {
      final opened = await vault.vaultOpen(
        path: '${dir.path}/vault.db',
        password: 'forward rules bridge password',
        create: true,
      );
      token = opened.token;
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
            'id': 'h1',
            'name': 'Saved',
            'host': '127.0.0.1',
            'username': 'wterm',
            'port': 22,
            'group': '',
            'tags': <String>[],
            'favorite': false,
          },
        ]),
      );
      final session = NativeVaultSession(token, false);
      final saved = await session.saveForwardRule(
        const forward.ForwardRule(
          id: '',
          hostId: 'h1',
          name: 'Web',
          kind: 'remote',
          listenHost: '127.0.0.1',
          listenPort: 0,
          targetHost: '127.0.0.1',
          targetPort: 80,
        ),
      );
      expect(saved.id, isNotEmpty);
      expect((await session.forwardRules('h1')).single.name, 'Web');
      final updated = await session.saveForwardRule(
        forward.ForwardRule(
          id: saved.id,
          hostId: 'h1',
          name: 'Web 2',
          kind: 'remote',
          listenHost: '127.0.0.1',
          listenPort: 0,
          targetHost: '127.0.0.1',
          targetPort: 80,
        ),
      );
      expect(updated.name, 'Web 2');
      await session.deleteForwardRule(saved.id);
      expect(await session.forwardRules('h1'), isEmpty);
    } finally {
      if (token != null) await vault.vaultLock(token: token);
      await dir.delete(recursive: true);
      RustLib.dispose();
    }
  });
}
