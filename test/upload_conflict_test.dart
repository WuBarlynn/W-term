import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/upload_conflict_dialog.dart';
import 'package:wterm/app/upload_conflict.dart';

void main() {
  test(
    'skip choice can apply to remaining conflicts without prompting again',
    () async {
      final decisions = UploadConflictDecisions();
      expect(
        await decisions.resolve(
          () async => const UploadConflictChoice(
            UploadConflictAction.skip,
            applyToRemaining: true,
          ),
        ),
        'skip',
      );
      expect(
        await decisions.resolve(() async {
          fail('must not prompt again');
        }),
        'skip',
      );
    },
  );

  test('unchecked choices prompt separately and checked choice applies to remaining', () async {
    final decisions = UploadConflictDecisions();
    var prompts = 0;
    Future<UploadConflictChoice?> ask() async {
      prompts++;
      return UploadConflictChoice(
        UploadConflictAction.keepBoth,
        applyToRemaining: prompts == 2,
      );
    }

    expect(await decisions.resolve(ask), 'keepBoth');
    expect(await decisions.resolve(ask), 'keepBoth');
    expect(await decisions.resolve(ask), 'keepBoth');
    expect(prompts, 2);
  });
  test(
    'retry or new batch does not inherit replacement authorization',
    () async {
      final first = UploadConflictDecisions();
      expect(
        await first.resolve(
          () async => const UploadConflictChoice(
            UploadConflictAction.replace,
            applyToRemaining: true,
          ),
        ),
        'replace',
      );
      final retry = UploadConflictDecisions();
      var asked = false;
      expect(
        await retry.resolve(() async {
          asked = true;
          return null;
        }),
        isNull,
      );
      expect(asked, isTrue);
    },
  );
  testWidgets('phone can explicitly apply keep-both to remaining conflicts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    UploadConflictChoice? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                choice = await chooseUploadConflict(context, '配置文件');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留两个文件'));
    await tester.pumpAndSettle();
    expect(choice!.action, UploadConflictAction.keepBoth);
    expect(choice!.applyToRemaining, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final entry in {
    '替换': 'replace',
    '跳过': 'skip',
    '保留两个文件': 'keepBoth',
    '取消': null,
  }.entries) {
    testWidgets('upload conflict ${entry.key} requires an explicit choice', (
      tester,
    ) async {
      UploadConflictChoice? choice;
      var returned = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  choice = await chooseUploadConflict(context, 'settings.json');
                  returned = true;
                },
                child: const Text('upload'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('upload'));
      await tester.pumpAndSettle();
      expect(returned, isFalse);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(choice?.action.name, entry.value);
      if (choice != null) expect(choice!.applyToRemaining, isFalse);
    });
  }
}
