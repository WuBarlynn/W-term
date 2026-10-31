import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/ai_assistant.dart';
import 'package:wterm/app/keyword_highlights.dart';
import 'package:wterm/app/pinned_commands.dart';
import 'package:wterm/app/plugins.dart';
import 'package:wterm/app/synced_settings.dart';
import 'package:wterm/app/terminal_appearance.dart';

void main() {
  test('terminal appearance accepts synced values', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-settings');
    addTearDown(() => dir.delete(recursive: true));
    final store = TerminalAppearance(
      file: () async => File('${dir.path}/appearance.json'),
    );
    await store.applySynced({
      'palette': 'nord',
      'fontSize': 15,
      'uiTheme': 'dark',
      'terminalFont': 'Menlo',
      'skin': 'aurora',
      'copyOnSelect': true,
    });
    expect(store.palette, 'nord');
    expect(store.fontSize, 15);
    expect(store.uiTheme, 'dark');
    expect(store.terminalFont, 'Menlo');
    expect(store.skin, 'aurora');
    expect(store.copyOnSelect, isTrue);
    expect(store.toJson()['palette'], 'nord');
    expect(File('${dir.path}/appearance.json').existsSync(), isTrue);
  });

  test('plugin settings accept synced switches', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-settings');
    addTearDown(() => dir.delete(recursive: true));
    final store = PluginSettings(
      file: () async => File('${dir.path}/plugins.json'),
    );
    await store.applySynced({
      'jsonFormatter': false,
      'ipLookup': true,
      'filePreview': true,
      'commandCompletion': false,
      'taskNotifications': true,
      'imeAutoEnglish': true,
      'windowsHardwareInput': true,
      'linkUnderline': false,
      'dragUpload': false,
      'maxUploadSizeMb': 64,
      'compactTabs': true,
      'showFavoritesBar': false,
      'clickTabLocates': true,
      'restoreLayout': false,
      'showStatusBar': false,
      'rightClickPaste': true,
    });
    expect(store.jsonFormatter, isFalse);
    expect(store.commandCompletion, isFalse);
    expect(store.imeAutoEnglish, isTrue);
    expect(store.windowsHardwareInput, isTrue);
    expect(store.linkUnderline, isFalse);
    expect(store.dragUpload, isFalse);
    expect(store.maxUploadSizeMb, 64);
    expect(store.compactTabs, isTrue);
    expect(store.showFavoritesBar, isFalse);
    expect(store.clickTabLocates, isTrue);
    expect(store.restoreLayout, isFalse);
    expect(store.showStatusBar, isFalse);
    expect(store.rightClickPaste, isTrue);
    expect(store.toJson()['maxUploadSizeMb'], 64);
  });

  test('pinned commands and highlights accept synced values', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-settings');
    addTearDown(() => dir.delete(recursive: true));
    final pins = PinnedCommands(
      file: () async => File('${dir.path}/pinned.json'),
    );
    await pins.applySynced({
      'version': 1,
      'entries': [
        {'name': 'Uptime', 'command': 'uptime', 'tag': 'prod'},
      ],
    });
    expect(pins.entries.single.name, 'Uptime');
    expect(pins.entries.single.tag, 'prod');
    final highlights = KeywordHighlightSettings(
      file: () async => File('${dir.path}/highlights.json'),
    );
    await highlights.applySynced({
      'enabled': true,
      'keywords': ['error', 'failed'],
      'colorArgb': 0xffff0000,
    });
    expect(highlights.enabled, isTrue);
    expect(highlights.keywords, ['error', 'failed']);
    expect(highlights.colorArgb, 0xffff0000);
    expect(highlights.toJson()['keywords'], ['error', 'failed']);
  });

  test('appearance rejects an invalid palette without throwing', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-settings');
    addTearDown(() => dir.delete(recursive: true));
    final store = TerminalAppearance(
      file: () async => File('${dir.path}/appearance.json'),
    );
    await store.applySynced({'palette': 'missing', 'fontSize': 99});
    expect(store.palette, 'dark');
    expect(store.fontSize, 13);
  });

  test('export waits for an in-flight appearance save', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-settings');
    addTearDown(() => dir.delete(recursive: true));
    final store = TerminalAppearance(
      file: () async => File('${dir.path}/appearance.json'),
    );
    final saving = store.save('nord', 16);
    final exported = await store.exportSynced();
    await saving;
    expect(exported['palette'], 'nord');
    expect(exported['fontSize'], 16);
  });

  test('AI profiles round-trip with API keys in the settings payload', () {
    const settings = AiSettings(
      baseUrl: 'https://api.example.test/v1',
      model: 'test-model',
      apiKey: 'sk-fixture',
      permission: AiPermission.readOnly,
    );
    final decoded = SyncedAiCodec.decode(
      SyncedAiCodec.encode(
        const AiProfileSet(
          profiles: [
            AiProfile(id: 'work', name: 'Work', settings: settings),
            AiProfile(id: 'home', name: 'Home', settings: AiSettings()),
          ],
          activeId: 'home',
        ),
      ),
    );
    expect(decoded, isNotNull);
    expect(decoded!.activeId, 'home');
    expect(decoded.profiles, hasLength(2));
    expect(decoded.profiles.first.settings.apiKey, 'sk-fixture');
    expect(decoded.profiles.first.settings.model, 'test-model');
    expect(decoded.profiles.first.settings.permission, AiPermission.readOnly);
    expect(SyncedAiCodec.decode({'profiles': []}), isNull);
    expect(SyncedAiCodec.decode(null), isNull);
  });
}
