import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/remote_permissions_dialog.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    Future<void> Function(int) save,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => RemotePermissionsDialog(
                  name: 'config',
                  permissions: 420,
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

  testWidgets('invalid modes are rejected and checkbox produces octal value', (
    tester,
  ) async {
    int? saved;
    await open(tester, (value) async {
      saved = value;
    });
    expect(find.text('644'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '888');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text('请输入 000 至 777 的三位权限'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '644');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('permission-0-2')));
    await tester.pump();
    expect(find.text('744'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved, 484);
    expect(find.byType(RemotePermissionsDialog), findsNothing);
  });
  testWidgets('unchanged permissions do not send a write', (tester) async {
    var calls = 0;
    await open(tester, (_) async {
      calls++;
    });
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });
  testWidgets('pending write prevents repeat and failure keeps editor open', (
    tester,
  ) async {
    var calls = 0;
    final result = Completer<void>();
    await open(tester, (_) {
      calls++;
      return result.future;
    });
    await tester.enterText(find.byType(TextFormField), '600');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.tap(find.text('取消'));
    expect(calls, 1);
    result.completeError(StateError('permission denied'));
    await tester.pumpAndSettle();
    expect(find.textContaining('permission denied'), findsOneWidget);
    expect(find.byType(RemotePermissionsDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
