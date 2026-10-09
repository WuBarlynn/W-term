import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/sync_store.dart';
import 'package:wterm/features/sync_disconnect_dialog.dart';

import 'sync_dialog_test.dart' show MemorySync, tap, show;

class DisconnectStore extends MemorySync {
  int disconnects = 0;
  String? revision, typed;
  bool blocked = false, fail = false;
  Completer<void>? pending;
  @override
  Future<SyncDisconnectInfo> disconnectPreview() async => SyncDisconnectInfo(
    'rev-1',
    'fixture/vault · main',
    initialized: true,
    blockedReason: blocked ? '请先恢复待处理同步' : '',
  );
  @override
  Future<void> disconnectSync(String revision, String confirmation) async {
    disconnects++;
    this.revision = revision;
    typed = confirmation;
    if (fail) throw StateError('仓库已变化，请重新检查');
    if (pending != null) await pending!.future;
    profile = const SyncProfile();
  }
}

const ack = '我已保存所需恢复凭证和备份，理解本机旧同步密钥将移除';
Future<void> open(WidgetTester t, DisconnectStore s) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SyncDisconnectDialog(store: s),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tap(t, find.text('open'));
}

void main() {
  testWidgets(
    'requires backup acknowledgement and exact phrase; cancel keeps binding',
    (t) async {
      final s = DisconnectStore();
      await open(t, s);
      final button = find.widgetWithText(FilledButton, '确认断开');
      expect(find.text('fixture/vault · main'), findsOneWidget);
      await t.enterText(find.byType(TextField), '断开');
      await t.pump();
      expect(t.widget<FilledButton>(button).onPressed, isNull);
      await tap(t, find.text(ack));
      await t.enterText(find.byType(TextField), 'wrong');
      await t.pump();
      expect(t.widget<FilledButton>(button).onPressed, isNull);
      await tap(t, find.text('取消'));
      expect(s.disconnects, 0);
      await tap(t, find.text('open'));
      await tap(t, find.text(ack));
      await t.enterText(find.byType(TextField), '断开');
      await t.pump();
      await tap(t, button);
      expect(s.disconnects, 1);
      expect(s.revision, 'rev-1');
      expect(s.typed, '断开');
    },
  );
  testWidgets(
    'pending publication blocks unlink; failed save requires new confirmation',
    (t) async {
      final s = DisconnectStore()..blocked = true;
      await open(t, s);
      expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认断开'))
            .onPressed,
        isNull,
      );
      await tap(t, find.text('取消'));
      s.blocked = false;
      s.fail = true;
      await tap(t, find.text('open'));
      await tap(t, find.text(ack));
      await t.enterText(find.byType(TextField), '断开');
      await t.pump();
      await tap(t, find.text('确认断开'));
      expect(find.textContaining('仓库已变化'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tap(t, find.text('重新检查断开信息'));
      expect(
        t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
    },
  );
  testWidgets(
    'parent clears old configuration and allows a different repository',
    (t) async {
      final s = DisconnectStore()..ready();
      await show(t, s);
      await tap(t, find.text('断开 / 更换同步仓库'));
      await tap(t, find.text(ack));
      await t.enterText(find.widgetWithText(TextField, '输入“断开”确认'), '断开');
      await t.pump();
      await tap(t, find.text('确认断开'));
      expect(find.textContaining('已断开旧仓库'), findsOneWidget);
      final owner = find.widgetWithText(TextField, '仓库所有者');
      expect(t.widget<TextField>(owner).enabled, isTrue);
      expect(t.widget<TextField>(owner).controller!.text, isEmpty);
      expect(
        t
            .widget<TextField>(find.widgetWithText(TextField, 'GitHub 令牌'))
            .controller!
            .text,
        isEmpty,
      );
    },
  );
  testWidgets('small phone unlink prevents close while committing', (t) async {
    t.view.physicalSize = const Size(390, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final s = DisconnectStore()..pending = Completer<void>();
    await open(t, s);
    await tap(t, find.text(ack));
    await t.enterText(find.byType(TextField), '断开');
    await t.pump();
    await t.ensureVisible(find.text('确认断开'));
    await t.tap(find.text('确认断开'));
    await t.pump();
    expect(
      t.widget<TextButton>(find.widgetWithText(TextButton, '取消')).onPressed,
      isNull,
    );
    expect(t.takeException(), isNull);
    s.pending!.complete();
    await t.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });
}
