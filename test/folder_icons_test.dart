import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/folder_icons.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wterm-folder-icons-');
    file = File('${directory.path}/folder-icons.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('folder icons round-trip and follow folder renames', () async {
    final store = FolderIconStore(file: () async => file);
    await store.setIcon('Work/Servers', 'database');
    expect(store.iconFor('Work/Servers'), 'database');
    await store.renamePrefix('Work', 'Office');
    expect(store.iconFor('Work/Servers'), FolderIconStore.defaultIcon);
    expect(store.iconFor('Office/Servers'), 'database');
    final restored = FolderIconStore(file: () async => file);
    await restored.load();
    expect(restored.iconFor('Office/Servers'), 'database');
    await restored.removePrefix('Office');
    expect(restored.iconFor('Office/Servers'), FolderIconStore.defaultIcon);
  });

  test('synced folder icons reject invalid entries', () async {
    final store = FolderIconStore(file: () async => file);
    await store.applySynced({
      'Work': 'terminal',
      '': 'bad',
      'Bad': 42,
      'Huge': 'x' * 3000,
    });
    expect(store.iconFor('Work'), 'terminal');
    expect(store.iconFor(''), FolderIconStore.defaultIcon);
    expect(store.iconFor('Bad'), FolderIconStore.defaultIcon);
    expect(store.iconFor('Huge'), FolderIconStore.defaultIcon);
  });
}
