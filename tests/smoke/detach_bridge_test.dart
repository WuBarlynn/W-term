import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wterm/app/terminal_session.dart';
import 'package:wterm/src/rust/api/client.dart' as client;
import 'package:wterm/src/rust/frb_generated.dart';

String bufferText(TerminalSession session) {
  final lines = session.terminal.buffer.lines;
  final text = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    text.writeln(lines[i].getText());
  }
  return text.toString();
}

Future<void> waitFor(bool Function() condition, String label) async {
  await Future<void>.delayed(Duration.zero);
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for $label');
}

void main() {
  test(
    'handoff keeps the SSH connection alive for a second terminal view',
    () async {
      const library = String.fromEnvironment('WTERM_NATIVE_LIB');
      const port = int.fromEnvironment('WTERM_TEST_PORT');
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      String? id;
      TerminalSession? first;
      TerminalSession? second;
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
        first = TerminalSession(
          connectionId: id,
          host: '127.0.0.1',
          username: 'wterm',
          onEnded: () {},
        );
        await waitFor(
          () => bufferText(first!).trim().isNotEmpty,
          'initial terminal output',
        );
        final snapshot = await first.detachForHandoff();
        expect(snapshot, isNotEmpty);
        second = TerminalSession.attach(
          connectionId: id,
          host: '127.0.0.1',
          username: 'wterm',
          snapshot: snapshot,
          onEnded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        second.send('echo detach-ok\n');
        await waitFor(
          () => bufferText(second!).contains('detach-ok'),
          'output after handoff',
        );
        expect(second.ended, isFalse);
        await second.close();
        second = null;
        id = null;
      } finally {
        if (second != null) await second.close();
        if (id != null) await client.disconnect(connectionId: id);
        first?.dispose();
        RustLib.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
