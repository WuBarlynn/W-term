import 'package:flutter/foundation.dart';

enum DownloadState { waiting, running, completed, failed, cancelled }

class DownloadItem {
  final String name;
  final String remotePath;
  final bool isDirectory;
  DownloadState state = DownloadState.waiting;
  String? detail;
  DownloadItem(this.name, this.remotePath, {this.isDirectory = false});
}

/// A batch of downloads sharing one local destination. Cancelling only stops
/// waiting items; the file already being written is allowed to finish.
class DownloadBatch extends ChangeNotifier {
  final String destination;
  final List<DownloadItem> tasks;
  bool cancelRequested = false;
  bool active = true;

  DownloadBatch(this.destination, Iterable<DownloadItem> items)
    : tasks = List.unmodifiable(items);

  int count(DownloadState state) =>
      tasks.where((task) => task.state == state).length;

  bool start(int index) {
    if (!active ||
        cancelRequested ||
        tasks[index].state != DownloadState.waiting) {
      return false;
    }
    tasks[index].state = DownloadState.running;
    notifyListeners();
    return true;
  }

  void progress(int index, String detail) {
    if (tasks[index].state != DownloadState.running) return;
    tasks[index].detail = detail;
    notifyListeners();
  }

  void complete(int index, String detail) =>
      _finish(index, DownloadState.completed, detail);

  void fail(int index, String detail) =>
      _finish(index, DownloadState.failed, detail);

  void _finish(int index, DownloadState state, String detail) {
    if (tasks[index].state != DownloadState.running) return;
    tasks[index].state = state;
    tasks[index].detail = detail;
    notifyListeners();
  }

  void cancelRemaining() {
    if (!active || cancelRequested) return;
    cancelRequested = true;
    for (final task in tasks) {
      if (task.state == DownloadState.waiting) {
        task.state = DownloadState.cancelled;
      }
    }
    notifyListeners();
  }

  void finish() {
    for (final task in tasks) {
      if (task.state == DownloadState.waiting ||
          task.state == DownloadState.running) {
        task.state = DownloadState.cancelled;
      }
    }
    active = false;
    notifyListeners();
  }
}

String downloadStateLabel(DownloadState state) => switch (state) {
  DownloadState.waiting => '等待',
  DownloadState.running => '下载中',
  DownloadState.completed => '完成',
  DownloadState.failed => '失败',
  DownloadState.cancelled => '已取消',
};

/// Application-wide download queue. The batch keeps running when its
/// originating file pane is disposed (tab switch or pane close) so another tab
/// can observe progress and cancel remaining items.
class DownloadQueue extends ChangeNotifier {
  DownloadBatch? batch;
  bool running = false;

  void begin(DownloadBatch next) {
    batch = next;
    running = true;
    notifyListeners();
  }

  void finish() {
    running = false;
    notifyListeners();
  }
}

final downloadQueue = DownloadQueue();
