import 'package:flutter/foundation.dart';

import 'errors.dart';

enum DownloadOutcome { saved, shared, cancelled, unconfirmed }

class DownloadTask extends ChangeNotifier {
  final String name;
  final String remotePath;
  bool active = false;
  String status = '等待下载';
  String? error;
  String? cleanupWarning;
  int? bytes;
  DownloadOutcome? outcome;
  DownloadTask(this.name, this.remotePath);

  Future<void> run({
    required Future<int> Function() fetch,
    required Future<DownloadOutcome> Function() deliver,
    required Future<void> Function() cleanup,
  }) async {
    if (active) return;
    active = true;
    error = null;
    cleanupWarning = null;
    bytes = null;
    outcome = null;
    status = '下载中';
    notifyListeners();
    try {
      bytes = await fetch();
      status = '等待保存或分享';
      notifyListeners();
      outcome = await deliver();
      status = switch (outcome!) {
        DownloadOutcome.saved => '已保存到本地',
        DownloadOutcome.shared => '分享操作已完成',
        DownloadOutcome.cancelled => '已取消保存或分享',
        DownloadOutcome.unconfirmed => '分享结果未确认',
      };
    } catch (e) {
      error = userFacingError(e);
      status = '下载或保存失败';
    } finally {
      try {
        await cleanup();
      } catch (e) {
        cleanupWarning = '临时文件清理失败：${userFacingError(e)}';
      }
      active = false;
      notifyListeners();
    }
  }
}
