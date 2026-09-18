import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/upload_conflict_dialog.dart';

void main() {
  for (final entry in {
    '替换': 'replace',
    '保留两个文件': 'keepBoth',
    '取消': null,
  }.entries) {
    testWidgets('upload conflict ${entry.key} requires an explicit choice', (
      tester,
    ) async {
      String? choice = 'unchanged';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  choice = await chooseUploadConflict(context, 'settings.json');
                },
                child: const Text('upload'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('upload'));
      await tester.pumpAndSettle();
      expect(choice, 'unchanged');
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(choice, entry.value);
    });
  }
}
