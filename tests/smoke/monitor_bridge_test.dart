import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/src/rust/api/client.dart' as client;
import 'package:wterm/src/rust/frb_generated.dart';

void main() {
  test(
    'remote command uses an independent channel and bounded output',
    () async {
      const library = String.fromEnvironment('WTERM_NATIVE_LIB');
      const port = int.fromEnvironment('WTERM_TEST_PORT');
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      String? id;
      try {
        final identity = await client.probeServer(
          host: '127.0.0.1',
          port: port,
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
        final output = await client.runCommand(
          connectionId: id,
          command: 'echo monitor-ok; uname -s',
        );
        expect(output, contains('monitor-ok'));
        expect(output, isNotEmpty);
        await expectLater(
          client.runCommand(connectionId: id, command: ''),
          throwsA(anything),
        );
        await client.disconnect(connectionId: id);
        id = null;
      } finally {
        if (id != null) await client.disconnect(connectionId: id);
        RustLib.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
