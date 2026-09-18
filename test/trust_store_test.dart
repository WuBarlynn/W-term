import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/trust_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('fingerprints cannot be silently replaced', () async {
    final store = KeychainTrustStore();
    await store.remember('host:22', 'SHA256:original');
    await expectLater(
      store.remember('host:22', 'SHA256:changed'),
      throwsStateError,
    );
    expect((await store.read())['host:22'], 'SHA256:original');
    await store.forget('host:22');
    expect(await store.read(), isEmpty);
  });
  test('corrupt trust data fails closed', () async {
    FlutterSecureStorage.setMockInitialValues({
      'wterm.known-hosts.v1': 'not-json',
    });
    await expectLater(KeychainTrustStore().read(), throwsFormatException);
  });
  test('wrong value types fail closed', () async {
    FlutterSecureStorage.setMockInitialValues({
      'wterm.known-hosts.v1': jsonEncode({'host:22': 7}),
    });
    await expectLater(KeychainTrustStore().read(), throwsA(isA<TypeError>()));
  });
  test('endpoints normalize case and distinguish ports', () {
    expect(endpointKey(' HOST ', 22), 'host:22');
    expect(endpointKey('host', 2222), isNot(endpointKey('host', 22)));
  });
}
