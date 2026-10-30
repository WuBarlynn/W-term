import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/main.dart';

void main() {
  test('detached arguments are parsed as a string payload', () {
    final payload = detachedPayload([
      '--wterm-detached',
      jsonEncode({
        'connectionId': 'c1',
        'host': 'example.com',
        'username': 'root',
        'snapshot': 'line1\nline2',
        'title': 'root@example.com',
      }),
    ]);
    expect(payload?['connectionId'], 'c1');
    expect(payload?['host'], 'example.com');
    expect(payload?['snapshot'], 'line1\nline2');
  });

  test('missing or malformed detached payloads are ignored', () {
    expect(detachedPayload([]), isNull);
    expect(detachedPayload(['--wterm-detached']), isNull);
    expect(detachedPayload(['--wterm-detached', '{broken']), isNull);
    expect(detachedPayload(['--wterm-detached', '[]']), isNull);
  });
}
