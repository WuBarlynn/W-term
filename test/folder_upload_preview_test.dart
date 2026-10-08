import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/folder_upload.dart';
import 'package:wterm/features/folder_upload_preview.dart';

void main() {
  testWidgets(
    'excluding hidden items updates size and returns explicit selection',
    (tester) async {
      FolderUploadSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showDialog<FolderUploadSelection>(
                    context: context,
                    builder: (_) => FolderUploadPreview(
                      destination: '/',
                      items: [
                        FolderUploadItem('/local', 'root', true, null),
                        FolderUploadItem(
                          '/local/a',
                          'root/a',
                          false,
                          0,
                          scannedBytes: 10,
                        ),
                        FolderUploadItem(
                          '/local/.env',
                          'root/.env',
                          false,
                          0,
                          scannedBytes: 20,
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('2 个文件 · 1 个文件夹 · 30 B'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(find.text('1 个文件 · 1 个文件夹 · 10 B'), findsOneWidget);
      expect(find.text('root/.env'), findsNothing);
      await tester.tap(find.text('上传'));
      await tester.pumpAndSettle();
      expect(selected!.includeHidden, isFalse);
      expect(selected!.targetName, 'root');
    },
  );

  testWidgets('target name validates with phone keyboard and updates preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    FolderUploadSelection? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<FolderUploadSelection>(
                  context: context,
                  builder: (_) => FolderUploadPreview(
                    destination: '/remote',
                    items: [
                      FolderUploadItem('/local/root', 'root', true, null),
                    ],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '../bad');
    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('不能包含路径分隔符'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '备份');
    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(result?.targetName, '备份');
    expect(tester.takeException(), isNull);
  });

  test('size labels include large files without MiB overflow', () {
    expect(folderBytesLabel(0), '0 B');
    expect(folderBytesLabel(1024), '1.0 KiB');
    expect(folderBytesLabel(1024 * 1024 * 1024), '1.0 GiB');
  });
  for (final confirm in [false, true]) {
    testWidgets(
      'phone preview returns explicit $confirm with counts and paths',
      (tester) async {
        tester.view.physicalSize = const Size(390, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        FolderUploadSelection? chosen;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    chosen = await showDialog<FolderUploadSelection>(
                      context: context,
                      builder: (_) => FolderUploadPreview(
                        destination: '/remote',
                        items: [
                          FolderUploadItem('/local', '项目', true, null),
                          FolderUploadItem(
                            '/local/a',
                            '项目/a',
                            false,
                            0,
                            scannedBytes: 2048,
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(chosen, isNull);
        expect(find.text('1 个文件 · 1 个文件夹 · 2.0 KiB'), findsOneWidget);
        expect(find.text('项目/a'), findsOneWidget);
        await tester.tap(find.text(confirm ? '上传' : '取消'));
        await tester.pumpAndSettle();
        expect(chosen?.targetName, confirm ? '项目' : null);
        if (chosen != null) expect(chosen!.includeHidden, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
