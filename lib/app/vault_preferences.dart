import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Device-local vault launch policy. This is intentionally not synced.
class VaultPreferences {
  final Future<File> Function() _file;
  VaultPreferences({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/vault-preferences.json',
          ));

  bool autoUnlockOnLaunch = true;

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      if (value is Map) {
        autoUnlockOnLaunch = value['autoUnlockOnLaunch'] != false;
      }
    } on FileSystemException {
      // Keep defaults when the optional preference file is unavailable.
    } on FormatException {
      // Keep defaults after an interrupted write or manual edit.
    }
  }

  Future<void> save({bool? autoUnlockOnLaunchNext}) async {
    autoUnlockOnLaunch =
        autoUnlockOnLaunchNext ?? autoUnlockOnLaunch;
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'autoUnlockOnLaunch': autoUnlockOnLaunch}),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

final vaultPreferences = VaultPreferences();
