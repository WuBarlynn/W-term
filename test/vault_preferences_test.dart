import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/vault_preferences.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wterm-vault-prefs-');
    file = File('${directory.path}/prefs.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('auto unlock defaults on and round-trips', () async {
    final store = VaultPreferences(file: () async => file);
    await store.load();
    expect(store.autoUnlockOnLaunch, isTrue);
    await store.save(autoUnlockOnLaunchNext: false);
    final restored = VaultPreferences(file: () async => file);
    await restored.load();
    expect(restored.autoUnlockOnLaunch, isFalse);
  });

  test('damaged preferences keep the manual unlock default', () async {
    await file.writeAsString('{broken');
    final store = VaultPreferences(file: () async => file);
    await store.load();
    expect(store.autoUnlockOnLaunch, isTrue);
  });
}
