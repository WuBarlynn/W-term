import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/forward_store.dart';
import 'package:wterm/features/forwarding_dialog.dart';
import 'package:wterm/src/rust/api/forward.dart';

class Store implements ForwardingStore {
  List<ForwardInfo> entries = [];
  List<ForwardRule> saved = [];
  bool failList = false;
  int listCalls = 0;
  Completer<void>? stopPending;
  @override
  Future<List<ForwardInfo>> listForwards() async {
    listCalls++;
    if (failList && listCalls > 1) throw Exception('刷新失败');
    return List.of(entries);
  }

  @override
  Future<ForwardInfo> startForward({
    required String kind,
    required String listenHost,
    required int listenPort,
    String targetHost = '',
    int targetPort = 0,
  }) async {
    final info = ForwardInfo(
      id: 'f${entries.length + 1}',
      kind: kind,
      listenHost: listenHost,
      listenPort: listenPort == 0 ? 4567 : listenPort,
      targetHost: targetHost,
      targetPort: targetPort,
      listenRemote: kind == 'remote',
    );
    entries = [...entries, info];
    return info;
  }

  @override
  Future<void> stopForward(String id) async {
    await stopPending?.future;
    entries = entries.where((entry) => entry.id != id).toList();
  }

  @override
  Future<List<ForwardRule>> forwardRules() async => List.of(saved);
  @override
  Future<ForwardRule> saveForwardRule(ForwardRule rule) async {
    final value = rule.id.isEmpty
        ? ForwardRule(
            id: 'r${saved.length + 1}',
            hostId: rule.hostId,
            name: rule.name,
            kind: rule.kind,
            listenHost: rule.listenHost,
            listenPort: rule.listenPort,
            targetHost: rule.targetHost,
            targetPort: rule.targetPort,
          )
        : rule;
    saved = [...saved.where((item) => item.id != value.id), value];
    return value;
  }

  @override
  Future<void> deleteForwardRule(String id) async {
    saved = saved.where((rule) => rule.id != id).toList();
  }
}

ForwardRule rule({String name = 'Web', String kind = 'local'}) => ForwardRule(
  id: 'r1',
  hostId: 'h1',
  name: name,
  kind: kind,
  listenHost: '127.0.0.1',
  listenPort: 8080,
  targetHost: kind == 'dynamic' ? '' : 'internal.example',
  targetPort: kind == 'dynamic' ? 0 : 80,
);

Future<void> pump(WidgetTester tester, Store store, {String? hostId}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ForwardingDialog(store: store, hostId: hostId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder textField(String label) => find.widgetWithText(TextFormField, label);

void main() {
  testWidgets('validates, starts and stops a session forward', (tester) async {
    final store = Store();
    await pump(tester, store);
    await tester.tap(find.text('启动转发'));
    await tester.pumpAndSettle();
    expect(find.text('端口范围 1–65535'), findsOneWidget);
    expect(store.entries, isEmpty);
    await tester.enterText(textField('目标端口'), '80');
    await tester.tap(find.text('启动转发'));
    await tester.pumpAndSettle();
    expect(find.text('本地 -L · 本机 127.0.0.1:4567'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('停止转发 4567'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止转发 4567'));
    await tester.pumpAndSettle();
    expect(find.text('暂无转发'), findsOneWidget);
  });

  testWidgets('pending mutation disables actions and failure keeps entries', (
    tester,
  ) async {
    final store = Store()
      ..entries = [
        const ForwardInfo(
          id: 'one',
          kind: 'local',
          listenHost: '127.0.0.1',
          listenPort: 4567,
          targetHost: 'localhost',
          targetPort: 80,
          listenRemote: false,
        ),
      ];
    final pending = Completer<void>();
    store.stopPending = pending;
    await pump(tester, store);
    await tester.ensureVisible(find.byTooltip('停止转发 4567'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止转发 4567'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '刷新'))
          .onPressed,
      isNull,
    );
    pending.completeError(Exception('停止失败'));
    await tester.pumpAndSettle();
    expect(find.textContaining('停止失败'), findsOneWidget);
    expect(find.text('本地 -L · 本机 127.0.0.1:4567'), findsOneWidget);
  });

  testWidgets('successful start remains visible when list refresh fails', (
    tester,
  ) async {
    final store = Store()..failList = true;
    await pump(tester, store);
    await tester.enterText(textField('目标端口'), '80');
    await tester.tap(find.text('启动转发'));
    await tester.pumpAndSettle();
    expect(find.text('本地 -L · 本机 127.0.0.1:4567'), findsOneWidget);
    expect(find.textContaining('刷新失败'), findsOneWidget);
    expect(store.entries.length, 1);
  });

  testWidgets('non-loopback listener requires explicit confirmation', (
    tester,
  ) async {
    final store = Store();
    await pump(tester, store);
    await tester.enterText(textField('本地监听地址'), '0.0.0.0');
    await tester.pumpAndSettle();
    expect(find.textContaining('监听地址不是回环'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '启动转发'))
          .onPressed,
      isNull,
    );
    final confirm = find.text('我确认允许外部访问此监听地址');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '启动转发'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('starting a saved external rule asks for confirmation', (
    tester,
  ) async {
    final store = Store()
      ..saved = [
        const ForwardRule(
          id: 'r9',
          hostId: 'h1',
          name: 'Public',
          kind: 'local',
          listenHost: '0.0.0.0',
          listenPort: 9000,
          targetHost: '127.0.0.1',
          targetPort: 80,
        ),
      ];
    await pump(tester, store, hostId: 'h1');
    await tester.ensureVisible(find.byTooltip('启动规则 Public'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('启动规则 Public'));
    await tester.pumpAndSettle();
    expect(find.text('允许外部访问监听？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.entries, isEmpty);
    await tester.tap(find.byTooltip('启动规则 Public'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认启动'));
    await tester.pumpAndSettle();
    expect(store.entries.single.listenHost, '0.0.0.0');
  });

  testWidgets('saves, starts, edits and deletes a saved rule', (tester) async {
    final store = Store()..saved = [rule()];
    await pump(tester, store, hostId: 'h1');
    expect(find.text('Web'), findsOneWidget);
    expect(find.textContaining('本地 -L · 127.0.0.1:8080'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('启动规则 Web'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('启动规则 Web'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('停止规则 Web'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('停止规则 Web'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止规则 Web'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('启动规则 Web'), findsOneWidget);
    await tester.ensureVisible(find.text('Web'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Web'));
    await tester.pumpAndSettle();
    expect(find.text('更新规则'), findsOneWidget);
    await tester.enterText(textField('编辑规则名称'), 'Web 2');
    await tester.ensureVisible(find.text('更新规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新规则'));
    await tester.pumpAndSettle();
    expect(store.saved.single.name, 'Web 2');
    await tester.ensureVisible(find.byTooltip('规则操作：Web 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('规则操作：Web 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(store.saved, isEmpty);
  });

  testWidgets('saves a new dynamic rule without target fields', (tester) async {
    final store = Store();
    await pump(tester, store, hostId: 'h1');
    await tester.tap(find.text('动态 -D'));
    await tester.pumpAndSettle();
    expect(find.text('目标主机（服务器侧）'), findsNothing);
    await tester.enterText(textField('规则名称'), 'Socks');
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect(store.saved.single.kind, 'dynamic');
    expect(store.saved.single.targetHost, isEmpty);
    await tester.ensureVisible(find.text('Socks').last);
    expect(find.text('Socks'), findsWidgets);
  });

  testWidgets('phone keyboard layout scrolls without overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    final store = Store()
      ..entries = [
        const ForwardInfo(
          id: 'one',
          kind: 'local',
          listenHost: '127.0.0.1',
          listenPort: 4567,
          targetHost: 'localhost',
          targetPort: 80,
          listenRemote: false,
        ),
      ];
    await pump(tester, store);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('停止转发 4567'));
    expect(tester.takeException(), isNull);
  });
}
