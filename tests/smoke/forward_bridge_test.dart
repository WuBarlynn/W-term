import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/src/rust/frb_generated.dart';
import 'package:wterm/src/rust/api/client.dart' as client;
import 'package:wterm/src/rust/api/forward.dart' as forward;

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
}
