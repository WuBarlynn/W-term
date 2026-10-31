import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

abstract interface class FirstRunHost {}

class OnboardingStore extends ChangeNotifier {
  final Future<File> Function() _file;
  bool completed = false;
  bool loaded = false;
  Future<void> _pending = Future.value();

  OnboardingStore({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/onboarding.json',
          ));

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final value = jsonDecode(await file.readAsString());
        if (value is Map) completed = value['completed'] == true;
      }
    } catch (_) {
      // A broken onboarding marker only repeats the wizard.
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Future<void> complete() {
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'completed': true}),
        flush: true,
      );
      await temporary.rename(file.path);
      completed = true;
      notifyListeners();
    });
    _pending = operation;
    return operation;
  }
}

final onboarding = OnboardingStore();
