import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Cache directories may not exist on a fresh install or after OS cleanup.
Future<Directory> createAppTemporaryDirectory(
  String prefix, {
  Directory? root,
}) async {
  final parent = root ?? await getTemporaryDirectory();
  await parent.create(recursive: true);
  return parent.createTemp(prefix);
}
