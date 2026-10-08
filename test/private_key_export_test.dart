import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/private_key_export_dialog.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    Future<bool> Function(String) action,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => PrivateKeyExportDialog(onExport: action),
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

  Future<void> fill(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'independent export password',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'independent export password',
    );
  }

  testWidgets('validates password and confirmation before export', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, (_) async {
      calls++;
      return true;
    });
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('口令至少需要 12 个字符'), findsOneWidget);
    await fill(tester);
    await tester.enterText(find.byType(TextFormField).at(1), 'wrong');
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    expect(find.text('两次口令不一致'), findsOneWidget);
    expect(calls, 0);
  });
  testWidgets('cancelled save and failure allow retry; success closes dialog', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, (password) async {
      expect(password, 'independent export password');
      calls++;
      if (calls == 1) return false;
      if (calls == 2) throw StateError('disk failure');
      return true;
    });
    await fill(tester);
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    expect(find.text('已取消保存，尚未完成导出'), findsOneWidget);
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disk failure'), findsOneWidget);
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    expect(find.byType(PrivateKeyExportDialog), findsNothing);
  });
  testWidgets('pending export prevents duplicate submits and cancel', (
    tester,
  ) async {
    final completion = Completer<bool>();
    var calls = 0;
    await open(tester, (_) {
      calls++;
      return completion.future;
    });
    await fill(tester);
    await tester.tap(find.text('选择保存位置'));
    await tester.pump();
    await tester.tap(find.text('选择保存位置'));
    await tester.tap(find.text('取消'));
    expect(calls, 1);
    expect(find.byType(PrivateKeyExportDialog), findsOneWidget);
    completion.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(PrivateKeyExportDialog), findsNothing);
  });
}
