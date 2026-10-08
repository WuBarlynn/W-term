import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/remote_text_editor.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    Future<void> Function(String) save, {
    String text = 'original',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => RemoteTextEditor(
                  name: 'test.txt',
                  text: text,
                  onSave: save,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('preserves CRLF when saving edited text', (tester) async {
    String? saved;
    await open(tester, (text) async {
      saved = text;
    }, text: 'old\r\n');
    await tester.enterText(find.byType(TextField), '中文\nnext\n');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved, '中文\r\nnext\r\n');
    expect(find.byType(RemoteTextEditor), findsNothing);
  });
  testWidgets('dirty close requires discard and can keep editing', (
    tester,
  ) async {
    await open(tester, (_) async {});
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('changed'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteTextEditor), findsNothing);
  });
  testWidgets(
    'failed save retains buffer and prevents duplicate pending saves',
    (tester) async {
      final done = Completer<void>();
      var calls = 0;
      await open(tester, (_) {
        calls++;
        return done.future;
      });
      await tester.enterText(find.byType(TextField), 'my changes');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      expect(calls, 1);
      done.completeError(StateError('远程文件已变化'));
      await tester.pumpAndSettle();
      expect(find.text('my changes'), findsOneWidget);
      expect(find.textContaining('远程文件已变化'), findsOneWidget);
      expect(find.text('复制内容'), findsOneWidget);
    },
  );
  testWidgets('rejects oversized UTF-8 text before calling server', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, (_) async {
      calls++;
    });
    await tester.enterText(find.byType(TextField), '文' * 90000);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('最多 256 KiB'), findsWidgets);
  });
}
