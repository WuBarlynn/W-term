import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:wterm/app/temporary_directory.dart';
import 'package:wterm/app/identity_store.dart';
import 'package:wterm/features/vault_settings.dart';

class Maintenance implements VaultMaintenance {
  @override
  Future<void> changePassword(String current, String next) async {}
  @override
  Future<void> exportBackup(String path, String password) async {}
  @override
  Future<int> restoreBackup(String path, String password) async => 0;
}

void main() {
  test(
    'staging recreates missing cache parents and uses isolated directories',
    () async {
      final temp = await Directory.systemTemp.createTemp('wterm-cache-test-');
      try {
        final root = Directory('${temp.path}/Library/Caches/app');
        final first = await createAppTemporaryDirectory('backup-', root: root);
        final second = await createAppTemporaryDirectory('backup-', root: root);
        expect(first.path, isNot(second.path));
        final file = File('${first.path}/backup.db');
        await file.writeAsBytes([1, 2, 3]);
        expect(await file.readAsBytes(), [1, 2, 3]);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
  testWidgets('backup actions have comfortable spacing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VaultSettings(store: Maintenance())),
      ),
    );
    final buttons = find.byType(OutlinedButton);
    expect(buttons, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(buttons.at(i)).height, greaterThanOrEqualTo(48));
      if (i > 0) {
        expect(
          tester.getTopLeft(buttons.at(i)).dy -
              tester.getBottomLeft(buttons.at(i - 1)).dy,
          greaterThanOrEqualTo(12),
        );
      }
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'iOS soft keyboard deletes repeatedly and preserves composition',
    (tester) async {
      final terminal = Terminal();
      final output = <String>[];
      terminal.onOutput = output.add;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              deleteDetection: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  a',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(output.join(), 'a');
      output.clear();
      for (var i = 0; i < 2; i++) {
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: ' ',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();
      }
      expect(output.join(), '\x7f\x7f');
      output.clear();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  ni',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 2, end: 4),
        ),
      );
      await tester.pump();
      expect(output, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  你',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(output.join(), '你');
      output.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(output.join(), '\x7f');
    },
  );
}
