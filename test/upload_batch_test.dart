import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/upload_batch.dart';
import 'package:wterm/features/upload_tasks_dialog.dart';

void main() {
  test(
    'task filter combines case-insensitive path and status without mutation',
    () {
      final batch = UploadBatch('/', ['Dir/Config', 'dir/config.old', 'other']);
      batch.start(0);
      batch.fail(0, 'denied');
      batch.start(1);
      batch.complete(1, '/saved');
      expect(
        filterUploadTasks(
          batch.tasks,
          query: 'CONFIG',
          state: UploadState.failed,
        ),
        [batch.tasks[0]],
      );
      expect(filterUploadTasks(batch.tasks, query: 'absent'), isEmpty);
      expect(batch.tasks.length, 3);
      expect(batch.tasks[1].state, UploadState.completed);
    },
  );
  testWidgets('task search clears and state filter follows live changes', (
    tester,
  ) async {
    final batch = UploadBatch('/', ['Alpha', 'Beta']);
    batch.start(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UploadTasksDialog(batch: batch)),
      ),
    );
    await tester.enterText(find.byType(TextField), 'ALPHA');
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.byTooltip('清除任务搜索'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选任务状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '上传中'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsNothing);
    batch.complete(0, '/Alpha');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配任务'), findsOneWidget);
    expect(find.text('显示 0 / 2 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'filtered phone list still offers retry of all failures above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final batch = UploadBatch('/', ['Alpha', 'Beta']);
      for (final index in [0, 1]) {
        batch.start(index);
        batch.fail(index, 'denied');
      }
      batch.finish();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UploadTasksDialog(batch: batch, allowRetry: true),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pumpAndSettle();
      expect(find.text('显示 1 / 2 项'), findsOneWidget);
      expect(find.text('重试全部失败项（2）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'skipped file preserves server result and is excluded from failed retries',
    () {
      final batch = UploadBatch('/', ['existing', 'failed', 'next']);
      batch.start(0);
      batch.skip(0);
      expect(batch.start(1), isTrue);
      batch.fail(1, 'network');
      expect(batch.start(2), isTrue);
      batch.complete(2, '/next');
      batch.finish();
      expect(batch.tasks[0].state, UploadState.skipped);
      expect(batch.retryFailures(), [1]);
      expect(batch.tasks[0].state, UploadState.skipped);
      expect(batch.tasks[2].state, UploadState.completed);
    },
  );

  test('retry selects failures by index and preserves other outcomes', () {
    final batch = UploadBatch('/original', ['same', 'same', 'cancelled']);
    batch.start(0);
    batch.complete(0, '/original/same');
    batch.start(1);
    batch.fail(1, 'connection lost');
    batch.cancelRemaining();
    batch.finish();
    expect(batch.retryFailures(), [1]);
    expect(batch.cancelRequested, isFalse);
    expect(batch.tasks[0].state, UploadState.completed);
    expect(batch.tasks[0].detail, '/original/same');
    expect(batch.tasks[2].state, UploadState.cancelled);
    expect(batch.tasks[1].detail, isNull);
    expect(batch.destination, '/original');
    expect(batch.retryFailures(), isEmpty);
    expect(batch.start(1), isTrue);
    batch.complete(1, '/original/same (1)');
    batch.finish();
    expect(batch.failedIndices, isEmpty);
    expect(batch.retryFailures(), isEmpty);
    expect(batch.active, isFalse);
  });
  test(
    'retry failure can be retried again, cancellation stops queued retries',
    () {
      final batch = UploadBatch('/', ['a', 'b']);
      for (final index in [0, 1]) {
        batch.start(index);
        batch.fail(index, 'denied');
      }
      batch.finish();
      expect(batch.retryFailures(), [0, 1]);
      batch.start(0);
      batch.fail(0, 'still denied');
      batch.cancelRemaining();
      expect(batch.start(1), isFalse);
      batch.finish();
      expect(batch.retryFailures(), [0]);
    },
  );
  testWidgets(
    'retry is offered only after completion and returns explicit intent',
    (tester) async {
      final batch = UploadBatch('/', ['a']);
      batch.start(0);
      batch.fail(0, 'denied');
      bool? retry;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  retry = await showDialog<bool>(
                    context: context,
                    builder: (_) =>
                        UploadTasksDialog(batch: batch, allowRetry: true),
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
      expect(find.text('重试全部失败项（1）'), findsNothing);
      batch.finish();
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试全部失败项（1）'));
      await tester.pumpAndSettle();
      expect(retry, isTrue);
      expect(batch.tasks.single.state, UploadState.failed);
    },
  );

  test('cancel remaining preserves active upload and prevents next start', () {
    final batch = UploadBatch('/target', ['a', 'b', 'c']);
    expect(batch.start(0), isTrue);
    batch.cancelRemaining();
    expect(batch.tasks.map((t) => t.state), [
      UploadState.running,
      UploadState.cancelled,
      UploadState.cancelled,
    ]);
    batch.complete(0, '/target/a · 1 KiB');
    expect(batch.start(1), isFalse);
    batch.finish();
    expect(batch.tasks.first.state, UploadState.completed);
    expect(batch.active, isFalse);
  });
  test('failure allows next task and does not overwrite completed results', () {
    final batch = UploadBatch('/target', ['same', 'same']);
    batch.start(0);
    batch.fail(0, 'Permission denied');
    expect(batch.start(1), isTrue);
    batch.complete(1, '/target/same (1)');
    batch.cancelCurrent(1);
    batch.finish();
    expect(batch.tasks.first.state, UploadState.failed);
    expect(batch.tasks.first.detail, 'Permission denied');
    expect(batch.tasks.last.state, UploadState.completed);
  });
  test('finish marks unfinished entries cancelled and cannot restart', () {
    final batch = UploadBatch('/', ['a', 'b']);
    batch.start(0);
    batch.finish();
    expect(batch.tasks.every((t) => t.state == UploadState.cancelled), isTrue);
    expect(batch.start(1), isFalse);
  });
  test('conflict cancellation cancels current and remaining entries', () {
    final batch = UploadBatch('/', ['a', 'b']);
    batch.start(0);
    batch.cancelCurrent(0);
    batch.cancelRemaining();
    batch.finish();
    expect(batch.tasks.every((t) => t.state == UploadState.cancelled), isTrue);
  });
  testWidgets('phone task list updates live and cancels only pending tasks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final batch = UploadBatch('/上传目录', ['active.txt', 'pending.txt']);
    batch.start(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UploadTasksDialog(batch: batch)),
      ),
    );
    expect(find.text('上传中'), findsOneWidget);
    await tester.tap(find.text('取消剩余任务'));
    await tester.pump();
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('上传中'), findsOneWidget);
    batch.complete(0, '/上传目录/active.txt');
    batch.finish();
    await tester.pump();
    expect(find.textContaining('完成 · /上传目录/active.txt'), findsOneWidget);
    expect(find.text('取消剩余任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('application upload queue exposes one running batch across panes', () {
    uploadQueue.finish();
    final first = UploadBatch('/one', ['a']);
    uploadQueue.begin(first);
    expect(uploadQueue.running, isTrue);
    expect(identical(uploadQueue.batch, first), isTrue);
    first.finish();
    uploadQueue.finish();
    expect(uploadQueue.running, isFalse);
    final second = UploadBatch('/two', ['b']);
    uploadQueue.begin(second);
    expect(identical(uploadQueue.batch, second), isTrue);
    uploadQueue.finish();
  });
}
