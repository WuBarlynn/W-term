import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  final sample = HostProfile(
    id: 'a',
    name: '生产服务器',
    host: 'Example.com',
    username: 'alice',
    port: 2222,
    group: '生产',
    tags: ['API'],
    favorite: true,
  );
  test(
    'profiles survive store recreation with explicit credential-free schema',
    () async {
      await KeychainHostStore().write([sample]);
      final restored = (await KeychainHostStore().read()).single;
      expect(restored.toJson(), sample.toJson());
      expect(restored.toJson().keys.toSet(), {
        'id',
        'name',
        'host',
        'username',
        'port',
        'group',
        'tags',
        'favorite',
      });
      expect(restored.matches('api'), isTrue);
      expect(restored.matches('生产'), isTrue);
      expect(restored.matches(' ALICE '), isTrue);
      expect(restored.toggleFavorite().favorite, isFalse);
      expect(restored.favorite, isTrue);
    },
  );
  test('startup command and environment round-trip without credentials', () {
    final host = HostProfile(
      id: 'b',
      name: 'startup',
      host: 'example.com',
      username: 'alice',
      startupCommand: 'cd /srv/app',
      environment: ['APP_ENV=prod', 'TOKEN=a b'],
      icon: 'database',
      wiki: '# Runbook',
    );
    final restored = HostProfile.fromJson(host.toJson());
    expect(restored.startupCommand, 'cd /srv/app');
    expect(restored.environment, ['APP_ENV=prod', 'TOKEN=a b']);
    expect(restored.toJson()['environment'], ['APP_ENV=prod', 'TOKEN=a b']);
    expect(restored.toJson().containsKey('identityId'), isFalse);
    expect(restored.icon, 'database');
    expect(restored.wiki, '# Runbook');
    expect(restored.withWiki('# Runbook 2').wiki, '# Runbook 2');
    expect(restored.withWiki('# Runbook 2').icon, 'database');
    expect(restored.withWiki('# Runbook').startupCommand, 'cd /srv/app');
  });
  test('malformed and future data are not silently treated as empty', () async {
    for (final raw in [
      'invalid',
      jsonEncode({'version': 2, 'hosts': []}),
      jsonEncode({
        'version': 1,
        'hosts': [sample.toJson(), sample.toJson()],
      }),
    ]) {
      FlutterSecureStorage.setMockInitialValues({KeychainHostStore.key: raw});
      await expectLater(KeychainHostStore().read(), throwsFormatException);
      expect(
        await const FlutterSecureStorage().read(key: KeychainHostStore.key),
        raw,
      );
    }
  });
  test('duplicate write fails without replacing saved profiles', () async {
    final store = KeychainHostStore();
    await store.write([sample]);
    await expectLater(store.write([sample, sample]), throwsFormatException);
    expect((await store.read()).length, 1);
  });
  test('invalid ports rejected during deserialization', () {
    expect(
      () => HostProfile.fromJson({...sample.toJson(), 'port': 65536}),
      throwsFormatException,
    );
  });
}
