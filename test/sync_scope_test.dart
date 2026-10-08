import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/sync_store.dart';
import 'package:wterm/features/sync_scope_dialog.dart';

import 'sync_dialog_test.dart' show MemorySync, tap, show;

class ScopeStore extends MemorySync {
  List<SyncScopeKey> saved = [];
  int saves = 0;
  bool failSave = false, blocked = false;
  String? revision;
  @override
  Future<SyncScopeView> syncScope([List<SyncScopeKey>? selection]) async {
    final chosen = selection ?? saved;
    const host = SyncScopeKey('host', 'one');
    const identity = SyncScopeKey('identity', 'login');
    final excluded = chosen.contains(host) || chosen.contains(identity);
    return SyncScopeView('preview-${chosen.length}', [
      SyncScopeItem(
        host,
        'One',
        selected: chosen.contains(host),
        excluded: excluded,
      ),
      SyncScopeItem(
        identity,
        'Login',
        selected: chosen.contains(identity),
        excluded: excluded,
      ),
      const SyncScopeItem(
        SyncScopeKey('host', 'published'),
        'Published',
        published: true,
      ),
    ], blockedReason: blocked ? '请先完成待处理同步' : '');
  }

  @override
  Future<void> saveSyncScope(
    String revision,
    List<SyncScopeKey> selection,
  ) async {
    if (failSave) throw StateError('数据已变化，请刷新');
    saves++;
    this.revision = revision;
    saved = selection;
  }
}

Future<void> open(WidgetTester tester, ScopeStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SyncScopeDialog(store: store),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tap(tester, find.text('open'));
}

Finder row(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(CheckboxListTile));
void main() {
  testWidgets(
    'preview shows implied exclusions; confirmation saves only explicit choices',
    (tester) async {
      final store = ScopeStore();
      await open(tester, store);
      final save = find.widgetWithText(FilledButton, '保存范围');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(
        tester.widget<CheckboxListTile>(row('主机 · Published')).onChanged,
        isNull,
      );
      await tap(tester, find.text('主机 · One'));
      expect(find.text('仅本机 2 项（含关联项）'), findsOneWidget);
      expect(find.text('由关联主机或身份一起排除'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(row('身份 · Login')).value, isFalse);
      expect(store.saves, 0);
      await tap(tester, find.text('我已确认以上范围及关联影响'));
      await tap(tester, save);
      expect(store.saved, [const SyncScopeKey('host', 'one')]);
      expect(store.revision, 'preview-1');
    },
  );
  testWidgets('search preserves hidden choices and cancel writes nothing', (
    tester,
  ) async {
    final store = ScopeStore();
    await open(tester, store);
    await tap(tester, find.text('主机 · One'));
    await tester.enterText(find.byType(TextField), 'Login');
    await tester.pumpAndSettle();
    expect(find.text('主机 · One'), findsNothing);
    expect(find.text('仅本机 2 项（含关联项）'), findsOneWidget);
    await tap(tester, find.text('取消'));
    expect(store.saves, 0);
    await tap(tester, find.text('open'));
    expect(tester.widget<CheckboxListTile>(row('主机 · One')).value, isFalse);
  });
  testWidgets(
    'blocked batches cannot save; stale save requires fresh preview',
    (tester) async {
      final store = ScopeStore()..blocked = true;
      await open(tester, store);
      await tap(tester, find.text('主机 · One'));
      expect(find.text('请先完成待处理同步'), findsOneWidget);
      final save = find.widgetWithText(FilledButton, '保存范围');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tap(tester, find.text('取消'));
      store.blocked = false;
      store.failSave = true;
      await tap(tester, find.text('open'));
      await tap(tester, find.text('主机 · One'));
      await tap(tester, find.text('我已确认以上范围及关联影响'));
      await tap(tester, save);
      expect(find.textContaining('数据已变化'), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tap(tester, find.text('重新读取范围'));
      expect(tester.widget<CheckboxListTile>(row('主机 · One')).value, isFalse);
    },
  );
  testWidgets(
    'scope is accessible before recovery confirmation and disabled for dirty settings',
    (tester) async {
      final store = ScopeStore()
        ..profile = const SyncProfile(configured: true, initialized: true);
      await show(tester, store);
      final entry = find.widgetWithText(OutlinedButton, '管理仅本机范围');
      expect(tester.widget<OutlinedButton>(entry).onPressed, isNotNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'GitHub 令牌'),
        'changed',
      );
      await tester.pump();
      expect(tester.widget<OutlinedButton>(entry).onPressed, isNull);
    },
  );
  testWidgets('small phone with keyboard remains scrollable', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await open(tester, ScopeStore());
    await tester.enterText(find.byType(TextField), 'One');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tap(tester, find.text('取消'));
    expect(find.text('open'), findsOneWidget);
  });
}
