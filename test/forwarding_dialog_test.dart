import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/forwarding_dialog.dart';
import 'package:wterm/src/rust/api/forward.dart';

void main() {
  const entry = LocalForward(
    id: 'one',
    localPort: 4567,
    targetHost: 'localhost',
    targetPort: 80,
  );
  testWidgets('validates, starts and stops a session forward', (tester) async {
    final entries = <LocalForward>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForwardingDialog(
            onList: () async => List.of(entries),
            onStart: (local, host, port) async {
              expect(local, 0);
              expect(host, 'localhost');
              expect(port, 80);
              entries.add(entry);
              return entry;
            },
            onStop: (id) async {
              expect(id, 'one');
              entries.clear();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动转发'));
    await tester.pumpAndSettle();
    expect(find.text('端口范围 1–65535'), findsOneWidget);
    expect(entries, isEmpty);
    await tester.enterText(find.byType(TextFormField).at(0), 'localhost');
    await tester.enterText(find.byType(TextFormField).at(2), '80');
    await tester.tap(find.text('启动转发'));
    await tester.pumpAndSettle();
    expect(find.text('127.0.0.1:4567'), findsOneWidget);
    await tester.tap(find.byTooltip('停止转发 4567'));
    await tester.pumpAndSettle();
    expect(find.text('暂无转发'), findsOneWidget);
  });

  testWidgets('pending mutation disables actions and failure keeps entries', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForwardingDialog(
            onList: () async => [entry],
            onStart: (_, _, _) async => entry,
            onStop: (_) => pending.future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止转发 4567'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '关闭'))
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
    expect(find.text('127.0.0.1:4567'), findsOneWidget);
  });

  testWidgets('successful mutations remain visible when list refresh fails', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForwardingDialog(
            onList: () async {
              if (++reads > 1) throw Exception('刷新失败');
              return [];
            },
            onStart: (_, _, _) async => entry,
            onStop: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(2), '80');
    await tester.tap(find.text('启动转发'));
    await tester.pumpAndSettle();
    expect(find.text('127.0.0.1:4567'), findsOneWidget);
    expect(find.textContaining('刷新失败'), findsOneWidget);
    await tester.tap(find.byTooltip('停止转发 4567'));
    await tester.pumpAndSettle();
    expect(find.text('127.0.0.1:4567'), findsNothing);
  });

  testWidgets('phone keyboard layout scrolls without overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForwardingDialog(
            onList: () async => [entry],
            onStart: (_, _, _) async => entry,
            onStop: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('停止转发 4567'));
    expect(tester.takeException(), isNull);
  });
}
