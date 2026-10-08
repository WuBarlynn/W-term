import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/download_task.dart';
import 'package:wterm/features/download_task_dialog.dart';

void main() {
  for (final outcome in DownloadOutcome.values) {
    test('delivery $outcome is preserved and cleanup always runs', () async {
      final task = DownloadTask('a', '/a');
      var cleaned = false;
      await task.run(
        fetch: () async => 123,
        deliver: () async => outcome,
        cleanup: () async {
          cleaned = true;
        },
      );
      expect(task.outcome, outcome);
      expect(task.bytes, 123);
      expect(task.active, isFalse);
      expect(cleaned, isTrue);
      if (outcome == DownloadOutcome.cancelled) {
        expect(task.status, '已取消保存或分享');
      }
      if (outcome == DownloadOutcome.unconfirmed) {
        expect(task.status, '分享结果未确认');
      }
    });
  }
  test(
    'fetch failure skips save and cleanup failure does not hide original error',
    () async {
      final task = DownloadTask('a', '/a');
      await task.run(
        fetch: () async => throw StateError('network failed'),
        deliver: () async {
          fail('must not save');
        },
        cleanup: () async => throw StateError('cleanup failed'),
      );
      expect(task.error, contains('network failed'));
      expect(task.cleanupWarning, contains('cleanup failed'));
      expect(task.active, isFalse);
    },
  );
  test('save failure can retry and clears previous failure', () async {
    final task = DownloadTask('a', '/a');
    var cleanups = 0;
    await task.run(
      fetch: () async => 2,
      deliver: () async => throw StateError('disk full'),
      cleanup: () async {
        cleanups++;
      },
    );
    expect(task.error, contains('disk full'));
    await task.run(
      fetch: () async => 3,
      deliver: () async => DownloadOutcome.saved,
      cleanup: () async {
        cleanups++;
      },
    );
    expect(task.error, isNull);
    expect(task.bytes, 3);
    expect(task.status, '已保存到本地');
    expect(cleanups, 2);
  });
  test('active download rejects duplicate run and waits for cleanup', () async {
    final task = DownloadTask('a', '/a');
    final cleanup = Completer<void>();
    final running = task.run(
      fetch: () async => 1,
      deliver: () async => DownloadOutcome.saved,
      cleanup: () => cleanup.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(task.active, isTrue);
    await task.run(
      fetch: () async {
        fail('duplicate');
      },
      deliver: () async => DownloadOutcome.saved,
      cleanup: () async {},
    );
    cleanup.complete();
    await running;
    expect(task.active, isFalse);
  });
  testWidgets('phone dialog displays cancellation and explicit retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = DownloadTask('文件.txt', '/remote/文件.txt');
    await task.run(
      fetch: () async => 10,
      deliver: () async => DownloadOutcome.cancelled,
      cleanup: () async {},
    );
    bool? retry;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                retry = await showDialog<bool>(
                  context: context,
                  builder: (_) => DownloadTaskDialog(task: task),
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
    expect(find.text('已取消保存或分享'), findsOneWidget);
    await tester.tap(find.text('重新下载'));
    await tester.pumpAndSettle();
    expect(retry, isTrue);
    expect(tester.takeException(), isNull);
  });
}
