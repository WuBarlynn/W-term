import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_store.dart';
import 'package:wterm/app/openssh_config.dart';
import 'package:wterm/features/openssh_import_dialog.dart';

class ImportStore implements HostStore {
  List<HostProfile> hosts = [];
  bool fail = false;
  int writes = 0;
  @override
  Future<List<HostProfile>> read() async => List.of(hosts);
  @override
  Future<void> write(List<HostProfile> profiles) async {
    writes++;
    if (fail) throw StateError('storage unavailable');
    hosts = profiles;
  }
}

void main() {
  test('supported options agree with system OpenSSH effective configuration', () async {
    const source =
        'Host demo\n HostName example.invalid\n User deploy\nHost * !excluded\n Port 2222\nHost *\n Port 22';
    final directory = await Directory.systemTemp.createTemp(
      'wterm-config-test-',
    );
    try {
      final file = File('${directory.path}/config');
      await file.writeAsString(source);
      final result = await Process.run('/usr/bin/ssh', [
        '-G',
        '-F',
        file.path,
        'demo',
      ]);
      expect(result.exitCode, 0);
      final actual = result.stdout as String;
      final parsed = parseOpenSshConfig(source).single;
      expect(actual, contains('hostname ${parsed.hostname}\n'));
      expect(actual, contains('user ${parsed.username}\n'));
      expect(actual, contains('port ${parsed.port}\n'));
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
  test(
    'first obtained value, wildcard and negation match OpenSSH ordering',
    () {
      final entries = parseOpenSshConfig('''
Host prod lab
 HostName = "server.example" # comment
 User deploy
Host * !lab
 Port 2200
Host *
 User fallback
 Port 22
''');
      expect(entries.map((e) => e.username), ['deploy', 'deploy']);
      expect(entries.map((e) => e.port), [2200, 22]);
      expect(entries.map((e) => e.hostname), [
        'server.example',
        'server.example',
      ]);
      expect(entries.every((e) => e.canImport), true);
      final global = parseOpenSshConfig('User first\nHost host\n User second');
      expect(global.single.username, 'first');
    },
  );
  test('quoted hashes and identity paths remain data, with no automatic association', () {
    final entry = parseOpenSshConfig(
      'Host host\n User admin\n IdentityFile "~/my keys/id#one"',
    ).single;
    expect(entry.identityFiles, ['~/my keys/id#one']);
    expect(entry.profile().identityId, isEmpty);
  });
  test('blocks incomplete routing and conditional configs; never executes commands', () {
    final entry = parseOpenSshConfig(
      'Host jump\n User user\n ProxyCommand sh -c "touch /tmp/no"',
    ).single;
    expect(entry.canImport, false);
    expect(entry.issues, contains('暂不支持 proxycommand'));
    for (final source in [
      'Include other',
      'Match exec "anything"',
      'Host test\n User "broken',
      'Host test\n Port 22\\',
    ]) {
      expect(() => parseOpenSshConfig(source), throwsFormatException);
    }
  });
  test('requires username and validates port/address; wildcard-only configs yield no hosts', () {
    expect(parseOpenSshConfig('Host x').single.canImport, false);
    expect(
      parseOpenSshConfig('Host x', defaultUsername: 'user').single.canImport,
      true,
    );
    expect(
      parseOpenSshConfig('Host x\n User user\n Port 70000').single.canImport,
      false,
    );
    expect(
      parseOpenSshConfig('Host x\n User user\n HostName %h.example')
          .single
          .canImport,
      false,
    );
    expect(parseOpenSshConfig('Host *\n User user'), isEmpty);
  });
  test(
    'deduplicates repeated imports and keeps existing identity/favorite/group',
    () async {
      final store = ImportStore();
      store.hosts.add(
        HostProfile(
          id: 'old',
          name: 'x',
          host: 'x',
          username: 'user',
          favorite: true,
          identityId: 'secret-id',
          group: 'Keep',
        ),
      );
      final entries = parseOpenSshConfig('Host x y\n User user');
      expect(await importSshEntries(store, entries), 1);
      expect(store.hosts.first.identityId, 'secret-id');
      expect(store.hosts.first.favorite, true);
      expect(store.hosts.first.group, 'Keep');
      expect(store.hosts.last.group, 'OpenSSH 导入');
      expect(await importSshEntries(store, entries), 0);
      expect(store.writes, 1);
      store.fail = true;
      await expectLater(
        importSshEntries(store, parseOpenSshConfig('Host new\n User user')),
        throwsStateError,
      );
      expect(store.hosts.length, 2);
    },
  );
  testWidgets('preview selection persists only supported selected hosts', (
    tester,
  ) async {
    final store = ImportStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('open'),
              onPressed: () => showDialog<int>(
                context: context,
                builder: (_) => OpenSshImportDialog(
                  store: store,
                  initialSource: 'Host ok\n User user\nHost bad\n User user\n ProxyJump gateway',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览配置'));
    await tester.pumpAndSettle();
    expect(find.text('导入 1 台'), findsOneWidget);
    expect(store.hosts, isEmpty);
    await tester.tap(find.text('导入 1 台'));
    await tester.pumpAndSettle();
    expect(store.hosts.single.name, 'ok');
    expect(find.byType(OpenSshImportDialog), findsNothing);
  });
}
