import 'package:flutter/foundation.dart';

enum UploadState { waiting, running, completed, failed, cancelled, skipped }

class UploadTask {
  final String name;
  UploadState state = UploadState.waiting;
  String? detail;
  UploadTask(this.name);
}

/// One session-local batch. Cancellation never interrupts an atomic upload.
class UploadBatch extends ChangeNotifier {
  final String destination;
  final List<UploadTask> tasks;
  bool cancelRequested = false;
  bool active = true;
  UploadBatch(this.destination, Iterable<String> names)
    : tasks = List.unmodifiable(names.map(UploadTask.new));

  List<int> get failedIndices => [
    for (var i = 0; i < tasks.length; i++)
      if (tasks[i].state == UploadState.failed) i,
  ];

  /// Retry only failures, preserving successful and intentionally cancelled tasks.
  List<int> retryFailures() {
    if (active) return const [];
    final indices = failedIndices;
    if (indices.isEmpty) return indices;
    cancelRequested = false;
    active = true;
    for (final index in indices) {
      tasks[index].state = UploadState.waiting;
      tasks[index].detail = null;
    }
    notifyListeners();
    return indices;
  }

  bool start(int index) {
    if (!active ||
        cancelRequested ||
        tasks[index].state != UploadState.waiting) {
      return false;
    }
    tasks[index].state = UploadState.running;
    notifyListeners();
    return true;
  }

  void progress(int index, String detail) {
    if (tasks[index].state != UploadState.running) return;
    tasks[index].detail = detail;
    notifyListeners();
  }

  void complete(int index, String detail) =>
      _finish(index, UploadState.completed, detail);
  void fail(int index, String detail) =>
      _finish(index, UploadState.failed, detail);
  void skip(int index) => _finish(index, UploadState.skipped, '保留服务器已有项目');
  void cancelCurrent(int index) => _finish(index, UploadState.cancelled, null);

  void _finish(int index, UploadState state, String? detail) {
    if (tasks[index].state != UploadState.running) return;
    tasks[index].state = state;
    tasks[index].detail = detail;
    notifyListeners();
  }

  void cancelRemaining() {
    if (!active || cancelRequested) return;
    cancelRequested = true;
    for (final task in tasks) {
      if (task.state == UploadState.waiting) task.state = UploadState.cancelled;
    }
    notifyListeners();
  }

  void finish() {
    for (final task in tasks) {
      if (task.state == UploadState.waiting ||
          task.state == UploadState.running) {
        task.state = UploadState.cancelled;
      }
    }
    active = false;
    notifyListeners();
  }
}

String uploadStateLabel(UploadState state) => switch (state) {
  UploadState.waiting => '等待',
  UploadState.running => '上传中',
  UploadState.completed => '完成',
  UploadState.failed => '失败',
  UploadState.cancelled => '已取消',
  UploadState.skipped => '已跳过',
};

List<UploadTask> filterUploadTasks(
  Iterable<UploadTask> tasks, {
  String query = '',
  UploadState? state,
}) {
  final needle = query.toLowerCase();
  return tasks
      .where(
        (task) =>
            (state == null || task.state == state) &&
            task.name.toLowerCase().contains(needle),
      )
      .toList();
}

/// Application-wide upload queue. The batch keeps running when its originating
/// file pane is disposed so another tab can observe progress.
class UploadQueue extends ChangeNotifier {
  UploadBatch? batch;
  bool running = false;

  void begin(UploadBatch next) {
    batch = next;
    running = true;
    notifyListeners();
  }

  void finish() {
    running = false;
    notifyListeners();
  }
}

final uploadQueue = UploadQueue();
