import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/update_checker.dart';

void main() {
  test('version comparison handles v-prefix and build metadata', () {
    expect(isNewerVersion('v1.0.3', '1.0.2'), isTrue);
    expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
    expect(isNewerVersion('v1.0.2', '1.0.2'), isFalse);
    expect(isNewerVersion('1.0.1', '1.0.2'), isFalse);
    expect(isNewerVersion('v2.0.0+9', '1.99.99'), isTrue);
  });

  test('build-time version constant matches pubspec', () {
    final lines = File('pubspec.yaml').readAsLinesSync();
    final version = lines
        .firstWhere((line) => line.startsWith('version:'))
        .split(':')[1]
        .trim();
    expect(version, '$appVersion+$appBuild');
  });
}
