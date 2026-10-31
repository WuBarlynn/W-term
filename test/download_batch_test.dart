import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/download_batch.dart';

void main() {
  test('download batch runs, fails and cancels remaining items', () {
    final batch = DownloadBatch('/tmp/out', [
      DownloadItem('a.txt', '/a.txt'),
      DownloadItem('dir', '/dir', isDirectory: true),
      DownloadItem('c.txt', '/c.txt'),
    ]);
    expect(batch.count(DownloadState.waiting), 3);
    expect(batch.start(0), isTrue);
    batch.progress(0, '50%');
    expect(batch.tasks[0].detail, '50%');
    batch.complete(0, '已保存');
    expect(batch.start(1), isTrue);
    batch.fail(1, 'permission denied');
    expect(batch.count(DownloadState.completed), 1);
    expect(batch.count(DownloadState.failed), 1);

    batch.cancelRemaining();
    expect(batch.tasks[2].state, DownloadState.cancelled);
    expect(batch.start(2), isFalse);

    batch.finish();
    expect(batch.active, isFalse);
    expect(batch.count(DownloadState.cancelled), 1);
  });

  test('a cancelled batch never starts another item', () {
    final batch = DownloadBatch('/tmp/out', [
      DownloadItem('a', '/a'),
      DownloadItem('b', '/b'),
    ]);
    batch.cancelRemaining();
    expect(batch.start(0), isFalse);
    batch.finish();
    expect(batch.count(DownloadState.cancelled), 2);
  });
  queueTests();
}

void queueTests() {
  test('application download queue exposes the active batch', () {
    final queue = DownloadQueue();
    final batch = DownloadBatch('/tmp/q', [DownloadItem('a', '/a')]);
    expect(queue.running, isFalse);
    queue.begin(batch);
    expect(queue.batch, same(batch));
    expect(queue.running, isTrue);
    queue.finish();
    expect(queue.running, isFalse);
    expect(queue.batch, same(batch));
  });
}
