import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/sync_store.dart';
import 'package:wterm/features/sync_rotation_dialog.dart';

import 'sync_dialog_test.dart' show MemorySync, tap, show;

class RotationStore extends MemorySync {
  SyncRotation state = const SyncRotation(canBegin: true);
  int starts = 0, publishes = 0, discards = 0;
  String? batch, secret;
  bool failPublish = false, failRefresh = false;
  @override
  Future<SyncRotation> rotationStatus() async {
    if (failRefresh) throw StateError('读取状态失败');
    return state;
  }

  @override
  Future<String> beginRotation(String password) async {
    starts++;
    secret = password;
    state = const SyncRotation(batchId: 'batch-1', canDiscard: true);
    return 'synthetic-new-recovery';
  }

  @override
  Future<void> confirmRotation(String batchId, String code) async {
    batch = batchId;
    if (code != 'synthetic-new-recovery') throw StateError('恢复码无效');
    state = SyncRotation(
      batchId: batchId,
      recoveryConfirmed: true,
      canDiscard: true,
    );
  }

  @override
  Future<void> discardRotation(String batchId) async {
    batch = batchId;
    discards++;
    state = const SyncRotation(canBegin: true);
  }

  @override
  Future<String> publishRotation(String batchId) async {
    publishes++;
    batch = batchId;
    state = SyncRotation(batchId: batchId, recoveryConfirmed: true);
    if (operation != null) return operation!.future;
    if (failPublish) throw StateError('发布结果未知，请恢复核对');
    state = const SyncRotation(canBegin: true);
    return '轮换发布成功';
  }
}

Future<void> open(WidgetTester tester, RotationStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SyncRotationDialog(store: store)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'generate, verify, publish are separate with cleared secret inputs',
    (tester) async {
      final store = RotationStore();
      await open(tester, store);
      final generate = find.widgetWithText(FilledButton, '生成新密钥与恢复码');
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, '新的独立同步口令'),
        'synthetic-password',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '再次输入新同步口令'),
        'mismatch',
      );
      await tap(tester, find.text('我理解其他设备需要使用新凭证接入'));
      await tap(tester, generate);
      expect(store.starts, 0);
      expect(find.textContaining('两次输入'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
      await tester.enterText(
        find.widgetWithText(TextField, '新的独立同步口令'),
        'synthetic-password',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '再次输入新同步口令'),
        'synthetic-password',
      );
      await tap(tester, generate);
      expect(store.secret, 'synthetic-password');
      expect(find.text('synthetic-new-recovery'), findsOneWidget);
      expect(store.publishes, 0);
      final verify = find.widgetWithText(FilledButton, '核验新恢复码');
      expect(tester.widget<FilledButton>(verify).onPressed, isNull);
      final field = find.widgetWithText(TextField, '重新输入新恢复码');
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.enterText(field, 'wrong');
      await tap(tester, find.text('我已离线保存新恢复码'));
      await tap(tester, verify);
      expect(find.textContaining('恢复码无效'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.enterText(field, 'synthetic-new-recovery');
      await tap(tester, verify);
      expect(store.publishes, 0);
      expect(find.text('synthetic-new-recovery'), findsNothing);
      await tap(tester, find.text('发布 / 恢复轮换'));
      expect(store.batch, 'batch-1');
      expect(store.publishes, 1);
      expect(find.text('轮换发布成功'), findsOneWidget);
    },
  );

  testWidgets(
    'reopen retains pending state without reading recovery code; discard explicit',
    (tester) async {
      final store = RotationStore()
        ..state = const SyncRotation(batchId: 'retained', canDiscard: true);
      await open(tester, store);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('核验新恢复码'), findsOneWidget);
      final discard = find.widgetWithText(OutlinedButton, '丢弃未发布轮换');
      expect(tester.widget<OutlinedButton>(discard).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      expect(store.discards, 0);
      await open(tester, store);
      await tap(tester, find.text('我确认丢弃这次尚未发布的轮换'));
      await tap(tester, discard);
      expect(store.batch, 'retained');
      expect(store.discards, 1);
      expect(find.text('生成新密钥与恢复码'), findsOneWidget);
    },
  );

  testWidgets('unknown result disables discard and retry uses same batch', (
    tester,
  ) async {
    final store = RotationStore()
      ..state = const SyncRotation(
        batchId: 'retained',
        recoveryConfirmed: true,
        canDiscard: true,
      )
      ..failPublish = true;
    await open(tester, store);
    await tap(tester, find.text('发布 / 恢复轮换'));
    expect(find.textContaining('发布结果未知'), findsOneWidget);
    expect(find.text('丢弃未发布轮换'), findsNothing);
    expect(find.text('生成新密钥与恢复码'), findsNothing);
    store.failPublish = false;
    await tap(tester, find.text('发布 / 恢复轮换'));
    expect(store.batch, 'retained');
    expect(store.publishes, 2);
    expect(store.starts, 0);
  });

  testWidgets(
    'failed refresh blocks stale actions and cancellation fits phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = RotationStore()
        ..state = const SyncRotation(
          batchId: 'retained',
          recoveryConfirmed: true,
        )
        ..operation = Completer<String>();
      await open(tester, store);
      final publish = find.text('发布 / 恢复轮换');
      await tester.ensureVisible(publish);
      await tester.tap(publish);
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
            .onPressed,
        isNull,
      );
      store.failRefresh = true;
      await tester.tap(find.text('停止当前操作'));
      await tester.pumpAndSettle();
      expect(store.cancels, 1);
      expect(find.text('丢弃未发布轮换'), findsNothing);
      expect(publish, findsNothing);
      expect(tester.takeException(), isNull);
      store.failRefresh = false;
      await tap(tester, find.text('重新读取轮换状态'));
      expect(publish, findsOneWidget);
    },
  );

  testWidgets(
    'main sync page permits rotation resume but disables dirty settings',
    (tester) async {
      final store = RotationStore()..ready(pending: true);
      await show(tester, store);
      final entry = find.widgetWithText(OutlinedButton, '轮换 / 恢复同步密钥');
      expect(tester.widget<OutlinedButton>(entry).onPressed, isNotNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'GitHub 令牌'),
        'changed',
      );
      await tester.pump();
      expect(tester.widget<OutlinedButton>(entry).onPressed, isNull);
    },
  );
}
