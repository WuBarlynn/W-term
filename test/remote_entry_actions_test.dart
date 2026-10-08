import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/remote_entry_actions.dart';

void main() {
  for (final directory in [false, true]) {
    testWidgets(
      'file menu dispatches rename and delete; directory=$directory',
      (tester) async {
        var renamed = 0, deleted = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RemoteEntryActions(
                enabled: true,
                isDirectory: directory,
                onRename: () => renamed++,
                onDelete: () => deleted++,
                onDownload: () {},
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('文件操作'));
        await tester.pumpAndSettle();
        expect(find.text('下载'), directory ? findsNothing : findsOneWidget);
        await tester.tap(find.text('重命名'));
        await tester.pumpAndSettle();
        expect(renamed, 1);
        expect(deleted, 0);
        await tester.tap(find.byTooltip('文件操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        expect(deleted, 1);
      },
    );
  }
  testWidgets('deletion requires confirmation and explains link semantics', (
    tester,
  ) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                confirmed = await confirmRemoteDelete(
                  context,
                  name: 'link',
                  isDirectory: false,
                  isSymlink: true,
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
    expect(find.text('仅删除链接本身，保留链接指向的文件。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmed, false);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(confirmed, true);
  });
}
