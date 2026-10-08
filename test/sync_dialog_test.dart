import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/sync_store.dart';
import 'package:wterm/features/sync_dialog.dart';

class MemorySync implements SyncStore {
  @override
  Future<SyncScopeView> syncScope([List<SyncScopeKey>? selection]) async =>
      const SyncScopeView("fixture", []);
  @override
  Future<void> saveSyncScope(
    String revision,
    List<SyncScopeKey> selection,
  ) async {}
  SyncProfile profile = const SyncProfile(
    configured: true,
    tokenSaved: true,
    owner: 'fixture',
    repository: 'vault',
  );
  int setups = 0, runs = 0, cancels = 0, checks = 0;
  bool failCheck = false;
  @override
  Future<SyncRotation> rotationStatus() async => const SyncRotation();
  @override
  Future<String> beginRotation(String password) async =>
      throw UnimplementedError();
  @override
  Future<void> confirmRotation(String batchId, String code) async =>
      throw UnimplementedError();
  @override
  Future<void> discardRotation(String batchId) async =>
      throw UnimplementedError();
  @override
  Future<String> publishRotation(String batchId) async =>
      throw UnimplementedError();
  String? adoptedMode, adoptedSecret;
  bool failAdoption = false;
  @override
  Future<String> adoptSyncKey(String mode, String secret) async {
    adoptedMode = mode;
    adoptedSecret = secret;
    if (failAdoption) throw StateError('恢复码无效');
    return operation == null ? '新密钥已接入，请点击立即同步' : await operation!.future;
  }

  String? savedToken, confirmedCode;
  Completer<String>? operation;
  bool failRun = false;
  @override
  Future<SyncProfile> syncSettings() async => profile;
  @override
  Future<void> saveSyncSettings(
    String owner,
    String repository,
    String branch,
    String accessToken,
  ) async {
    savedToken = accessToken;
  }

  @override
  Future<String> checkSync() async {
    checks++;
    if (failCheck) {
      throw StateError('读取同步分支失败（GitHub HTTP 404）：请核对 Contents 权限');
    }
    return '仓库与分支读取成功';
  }

  @override
  Future<String> initializeSync(String mode, String secret) async {
    setups++;
    profile = const SyncProfile(
      configured: true,
      tokenSaved: true,
      initialized: true,
    );
    return 'fixture-recovery-code';
  }

  @override
  Future<void> confirmSyncRecovery(String code) async {
    confirmedCode = code;
    if (code != 'fixture-recovery-code') throw StateError('恢复码无效');
    ready();
  }

  void ready({bool pending = false}) {
    profile = SyncProfile(
      configured: true,
      tokenSaved: true,
      initialized: true,
      recoveryConfirmed: true,
      pending: pending,
    );
  }

  @override
  Future<String> runSync() async {
    runs++;
    if (failRun) {
      ready(pending: true);
      throw StateError('网络中断');
    }
    return operation == null ? '同步完成' : await operation!.future;
  }

  @override
  Future<SyncReview?> syncConflicts() async => null;
  @override
  Future<String> resolveSync(String reviewId, List<SyncChoice> choices) async =>
      '同步完成';
  @override
  Future<void> cancelSync() async {
    cancels++;
    operation?.completeError(StateError('同步已取消'));
  }
}

Future<void> show(WidgetTester tester, MemorySync store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SyncDialog(store: store)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'preflight checks saved settings without setup or upload and preserves failures',
    (tester) async {
      final store = MemorySync()..failCheck = true;
      await show(tester, store);
      await tap(tester, find.text('检查仓库与分支'));
      expect(find.textContaining('读取同步分支失败'), findsOneWidget);
      expect(store.setups, 0);
      expect(store.runs, 0);
      store.failCheck = false;
      await tap(tester, find.text('检查仓库与分支'));
      expect(find.text('仓库与分支读取成功'), findsOneWidget);
      expect(store.checks, 2);
      await tester.enterText(
        find.widgetWithText(TextField, 'GitHub 令牌'),
        'replacement',
      );
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '检查仓库与分支'),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('saved token stays blank and saving settings does not upload', (
    tester,
  ) async {
    final store = MemorySync();
    await show(tester, store);
    final field = find.widgetWithText(TextField, 'GitHub 令牌');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.enterText(field, 'replacement-token');
    await tap(tester, find.text('保存仓库设置'));
    expect(store.savedToken, 'replacement-token');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(store.runs, 0);
  });
  testWidgets(
    'create needs consent and recovery verification before manual upload',
    (tester) async {
      final store = MemorySync();
      await show(tester, store);
      final create = find.widgetWithText(FilledButton, '创建同步空间');
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, '独立同步口令'),
        'fixture sync password',
      );
      await tap(tester, find.text('允许加密同步主机、文件夹、身份和命令片段'));
      await tap(tester, create);
      expect(store.setups, 1);
      expect(store.runs, 0);
      expect(find.text('fixture-recovery-code'), findsOneWidget);
      final verify = find.widgetWithText(FilledButton, '核验恢复码');
      expect(tester.widget<FilledButton>(verify).onPressed, isNull);
      await tap(tester, find.text('我已离线保存恢复码'));
      await tester.enterText(
        find.widgetWithText(TextField, '重新输入恢复码'),
        'wrong',
      );
      await tap(tester, verify);
      expect(find.textContaining('恢复码无效'), findsOneWidget);
      expect(find.text('立即同步'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, '重新输入恢复码'),
        'fixture-recovery-code',
      );
      await tap(tester, verify);
      expect(store.confirmedCode, 'fixture-recovery-code');
      expect(find.text('fixture-recovery-code'), findsNothing);
      expect(store.runs, 0);
      await tap(tester, find.text('立即同步'));
      expect(store.runs, 1);
    },
  );
  testWidgets('unsaved token change blocks syncing until settings are saved', (
    tester,
  ) async {
    final store = MemorySync()..ready();
    await show(tester, store);
    await tester.enterText(
      find.widgetWithText(TextField, 'GitHub 令牌'),
      'replacement',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '立即同步'))
          .onPressed,
      isNull,
    );
    await tap(tester, find.text('保存仓库设置'));
    expect(store.runs, 0);
    await tap(tester, find.text('立即同步'));
    expect(store.runs, 1);
  });
  testWidgets('failed upload refreshes pending status and can retry', (
    tester,
  ) async {
    final store = MemorySync()
      ..ready()
      ..failRun = true;
    await show(tester, store);
    await tap(tester, find.text('立即同步'));
    expect(find.textContaining('网络中断'), findsOneWidget);
    expect(find.text('恢复待处理同步'), findsOneWidget);
    store.failRun = false;
    await tap(tester, find.text('恢复待处理同步'));
    expect(store.runs, 2);
  });
  testWidgets('inflight sync blocks close and cancel releases UI', (
    tester,
  ) async {
    final store = MemorySync()
      ..ready()
      ..operation = Completer<String>();
    await show(tester, store);
    await tester.ensureVisible(find.text('立即同步'));
    await tester.tap(find.text('立即同步'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNull,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tap(tester, find.text('取消操作'));
    expect(store.cancels, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('small phone with keyboard scrolls to recovery and actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(tester.view.reset);
    final store = MemorySync();
    store.profile = const SyncProfile(
      configured: true,
      initialized: true,
      tokenSaved: true,
    );
    await show(tester, store);
    await tester.ensureVisible(find.text('重新输入恢复码'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('重新生成恢复码'));
    expect(tester.takeException(), isNull);
  });
}
