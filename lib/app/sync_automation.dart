import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Local opt-in for periodic encrypted GitHub sync. Conflicts are never
/// resolved automatically; the user opens the sync review instead.
class SyncAutomation extends ChangeNotifier {
  final Future<File> Function() _file;
  bool enabled = false;
  int intervalMinutes = 15;

  SyncAutomation({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/sync-automation.json',
          ));

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return;
      enabled = value['enabled'] == true;
      final interval = value['intervalMinutes'];
      if (interval is int && interval >= 5 && interval <= 240) {
        intervalMinutes = interval;
      }
      notifyListeners();
    } catch (_) {
      // Automatic sync is optional.
    }
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    notifyListeners();
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'enabled': enabled,
        'intervalMinutes': intervalMinutes,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

final syncAutomation = SyncAutomation();
