import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/terminal_share_dialog.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('share dialog exposes templates, line numbers and watermark', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalShareDialog(
            title: 'Prod Web',
            lines: const ['deploy@web:~ \$ uptime', ' 10:21:00 up 12 days'],
            theme: TerminalThemes.defaultTheme,
            fontFamily: 'Menlo',
            fontSize: 12,
          ),
        ),
      ),
    );
    expect(find.text('分享为图片'), findsOneWidget);
    expect(find.text('终端窗口'), findsOneWidget);
    expect(find.text('渐变卡片'), findsOneWidget);
    expect(find.text('极简纯色'), findsOneWidget);
    expect(find.text('Prod Web'), findsWidgets);
    await tester.tap(find.text('渐变卡片'));
    await tester.pump();
    await tester.tap(find.text('行号'));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('W Term'), findsOneWidget);
    await tester.tap(find.text('水印'));
    await tester.pump();
    expect(find.textContaining('W Term'), findsNothing);
  });
}
