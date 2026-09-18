import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/terminal_search.dart';

void main() {
  testWidgets('history search filters snapshot, supports case and refresh', (
    tester,
  ) async {
    var lines = ['Error: denied', 'error: timeout', '连接成功'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalSearch(snapshot: () => [...lines])),
      ),
    );
    await tester.enterText(find.byType(TextField), 'error');
    await tester.pump();
    expect(find.text('匹配 2 行 · 当前历史快照'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(find.text('匹配 1 行 · 当前历史快照'), findsOneWidget);
    lines = ['新的连接成功'];
    await tester.enterText(find.byType(TextField), '成功');
    await tester.pump();
    expect(find.text('连接成功'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新历史快照'));
    await tester.pump();
    expect(find.text('新的连接成功'), findsOneWidget);
    expect(find.text('连接成功'), findsNothing);
  });
  testWidgets('phone search remains usable above the keyboard', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalSearch(snapshot: () => ['连接成功'])),
      ),
    );
    await tester.enterText(find.byType(TextField), '成功');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
