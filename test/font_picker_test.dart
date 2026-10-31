import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/terminal_appearance.dart';
import 'package:wterm/features/terminal_appearance_dialog.dart';

void main() {
  testWidgets('appearance dialog selects an installed or bundled font', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = TerminalAppearance(
      file: () async => throw UnimplementedError('not saved in this test'),
    );
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalAppearanceDialog(store: store)),
      ),
    );
    await tester.pumpAndSettle();
    final pickers = find.byTooltip('选择已安装或内置字体');
    expect(pickers, findsNWidgets(3));
    await tester.tap(pickers.at(1));
    await tester.pumpAndSettle();
    expect(find.text('选择字体'), findsOneWidget);
    expect(find.text('系统默认（留空）'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'JetBrains');
    await tester.pumpAndSettle();
    await tester.tap(find.text('JetBrains Mono').last);
    await tester.pumpAndSettle();
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[1].controller!.text, 'JetBrains Mono');
    expect(tester.takeException(), isNull);
  });
}
