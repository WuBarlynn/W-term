import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/sync_store.dart';
import 'package:wterm/features/sync_conflicts_dialog.dart';

import 'sync_dialog_test.dart' show MemorySync;

class ReviewStore extends MemorySync {
  SyncReview? review = const SyncReview('review-1', [
    SyncConflictEntry(
      kind: 'identity',
      id: 'login',
      localSummary: 'Mac login\n用户名：alice',
      remoteSummary: '已删除 / 不存在',
      localDeleted: false,
      remoteDeleted: true,
      changedFields: ['存在 / 删除状态'],
    ),
    SyncConflictEntry(
      kind: 'snippet',
      id: 'command',
      localSummary: 'Check\n命令长度：10 字符',
      remoteSummary: 'Check\n命令长度：12 字符',
      localDeleted: false,
      remoteDeleted: false,
      changedFields: ['命令（内容隐藏）'],
    ),
  ]);
  List<SyncChoice>? applied;
  bool fail = false, pendingFailure = false;
  Completer<String>? resolving;
  ReviewStore() {
    ready();
  }
  @override
  Future<SyncReview?> syncConflicts() async => review;
  @override
  Future<String> resolveSync(String reviewId, List<SyncChoice> choices) async {
    expect(reviewId, 'review-1');
    applied = choices;
    if (pendingFailure) {
      ready(pending: true);
      throw StateError('网络中断');
    }
    if (fail) throw StateError('远端已变化，请重新同步');
    return resolving == null ? '同步完成' : await resolving!.future;
  }

  @override
  Future<void> cancelSync() async {
    cancels++;
    resolving?.completeError(StateError('已取消'));
  }
}

Future<void> open(WidgetTester tester, ReviewStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (_) => SyncConflictsDialog(store: store),
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

Future<void> choose(WidgetTester tester, int index, String value) async {
  final f = find.byKey(ValueKey('conflict-choice-$index'));
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(f);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

Future<void> confirm(WidgetTester tester) async {
  final f = find.text('确认应用以上选择并继续同步');
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'no defaults; all choices plus confirmation required; cancel keeps data',
    (tester) async {
      final store = ReviewStore();
      await open(tester, store);
      final apply = find.widgetWithText(FilledButton, '应用并同步');
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await choose(tester, 0, '采用远端删除');
      await confirm(tester);
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await choose(tester, 1, '保留本机');
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await confirm(tester);
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(store.applied, isNull);
    },
  );
  testWidgets(
    'explicit choices reach store and successful sync closes review',
    (tester) async {
      final store = ReviewStore();
      await open(tester, store);
      await choose(tester, 0, '保留本机');
      await choose(tester, 1, '保留远端');
      await confirm(tester);
      await tester.tap(find.text('应用并同步'));
      await tester.pumpAndSettle();
      expect(store.applied!.map((c) => c.side), ['local', 'remote']);
      expect(find.byType(SyncConflictsDialog), findsNothing);
    },
  );
  testWidgets(
    'stale remote preserves choices; pending publication prevents reapply',
    (tester) async {
      final store = ReviewStore()..fail = true;
      await open(tester, store);
      await choose(tester, 0, '保留本机');
      await choose(tester, 1, '保留远端');
      await confirm(tester);
      await tester.tap(find.text('应用并同步'));
      await tester.pumpAndSettle();
      expect(find.textContaining('远端已变化'), findsOneWidget);
      store.fail = false;
      store.pendingFailure = true;
      await tester.tap(find.text('应用并同步'));
      await tester.pumpAndSettle();
      expect(find.textContaining('恢复待处理同步'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '应用并同步'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('cancel waits for native operation before enabling close', (
    tester,
  ) async {
    final store = ReviewStore()..resolving = Completer<String>();
    await open(tester, store);
    await choose(tester, 0, '保留本机');
    await choose(tester, 1, '保留远端');
    await confirm(tester);
    await tester.tap(find.text('应用并同步'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消操作'));
    await tester.pumpAndSettle();
    expect(store.cancels, 1);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('small screen review scrolls and deletion labels stay clear', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, ReviewStore());
    await choose(tester, 0, '采用远端删除');
    await choose(tester, 1, '保留本机');
    await confirm(tester);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用并同步'))
          .onPressed,
      isNotNull,
    );
  });
}
