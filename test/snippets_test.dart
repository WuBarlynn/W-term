import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/snippet_store.dart';
import 'package:wterm/features/snippets_dialog.dart';

class MemorySnippets implements SnippetStore {
  List<CommandSnippet> items = [const CommandSnippet('1', 'Disk', 'df -h')];
  bool failSave = false;
  @override
  Future<List<CommandSnippet>> readSnippets() async => List.of(items);
  @override
  Future<void> saveSnippet(String id, String name, String command) async {
    if (failSave) throw StateError('save unavailable');
    items.removeWhere((s) => s.id == id);
    items.add(CommandSnippet(id.isEmpty ? '2' : id, name, command));
  }

  @override
  Future<void> deleteSnippet(String id) async =>
      items.removeWhere((s) => s.id == id);
}

void main() {
  testWidgets('offline management edits without offering insertion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SnippetsDialog(store: MemorySnippets(), allowInsert: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disk'));
    await tester.pumpAndSettle();
    expect(find.text('编辑片段'), findsOneWidget);
    expect(find.text('插入，不执行'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'df -h'), findsOneWidget);
  });
  testWidgets('copy keeps exact command and dialog open', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SnippetsDialog(store: MemorySnippets(), allowInsert: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('片段操作：Disk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制命令'));
    await tester.pumpAndSettle();
    expect(copied, 'df -h');
    expect(find.text('片段已复制'), findsOneWidget);
    expect(find.text('命令片段'), findsOneWidget);
  });
  testWidgets('save failure retains edited draft and allows retry', (
    tester,
  ) async {
    final store = MemorySnippets()..failSave = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SnippetsDialog(store: store, allowInsert: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disk'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '名称'), '磁盘空间');
    await tester.enterText(find.widgetWithText(TextFormField, '单行命令'), 'df -H');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('save unavailable'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '磁盘空间'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'df -H'), findsOneWidget);
    expect(store.items.single.command, 'df -h');
    store.failSave = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('编辑片段'), findsNothing);
    expect(store.items.single.id, '1');
    expect(store.items.single.name, '磁盘空间');
    expect(store.items.single.command, 'df -H');
  });

  test('rejects newlines, terminal escapes and excessive UTF-8 payloads', () {
    for (final value in [
      '',
      'ls\nreboot',
      'ls\r',
      '\x1b[200~ls',
      '\x03',
      '字' * 6000,
    ]) {
      expect(validateSnippetCommand(value), isNotNull);
    }
    expect(validateSnippetCommand('docker ps --format "{{.Names}}"'), isNull);
  });
  testWidgets(
    'snippet requires explicit insertion and returns no added newline',
    (tester) async {
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  chosen = await showDialog<String>(
                    context: context,
                    builder: (_) => SnippetsDialog(store: MemorySnippets()),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disk'));
      await tester.pumpAndSettle();
      expect(chosen, isNull);
      await tester.tap(find.text('插入，不执行'));
      await tester.pumpAndSettle();
      expect(chosen, 'df -h');
    },
  );
  testWidgets('create validates multiline input, saves and searches', (
    tester,
  ) async {
    final store = MemorySnippets();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SnippetsDialog(store: store)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建片段'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '名称'),
      'Processes',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '单行命令'),
      'ps\naux',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.items.length, 1);
    await tester.enterText(
      find.widgetWithText(TextFormField, '单行命令'),
      'ps aux',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.items.length, 2);
    await tester.enterText(find.widgetWithText(TextField, '搜索片段'), 'process');
    await tester.pumpAndSettle();
    expect(find.text('Processes'), findsOneWidget);
    expect(find.text('Disk'), findsNothing);
  });
}
