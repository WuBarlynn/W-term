import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/snippet_market.dart';

void main() {
  test('bundled online catalog is valid and large', () async {
    final body = await File('docs/snippet-market.json').readAsString();
    final entries = parseSnippetMarket(body);
    expect(entries.length, greaterThanOrEqualTo(100));
    expect(entries.first.name, isNotEmpty);
    expect(entries.first.category, isNotEmpty);
  });

  test('remote entries reject malformed commands and duplicates', () {
    final entries = parseSnippetMarket(
      jsonEncode({
        'snippets': [
          {'name': 'ok', 'category': 'test', 'command': 'uptime'},
          {'name': 'bad', 'category': 'test', 'command': 'echo a > b'},
          {'name': 'ok', 'category': 'test', 'command': 'uptime'},
          {'name': '', 'category': 'test', 'command': 'date'},
          {'name': 'no cat', 'category': '', 'command': 'date'},
        ],
      }),
    );
    expect(entries.length, 1);
    expect(entries.single.command, 'uptime');
  });

  test('market caches a successful fetch and serves it offline', () async {
    final directory = await Directory.systemTemp.createTemp('wterm-market-');
    final file = File('${directory.path}/market.json');
    var fetches = 0;
    try {
      final service = SnippetMarket(
        cacheFile: () async => file,
        fetcher: (uri) async {
          fetches++;
          return jsonEncode({
            'snippets': [
              {'name': 'remote', 'category': 'net', 'command': 'uptime'},
            ],
          });
        },
      );
      final first = await service.load();
      expect(first.single.name, 'remote');
      expect(fetches, 1);
      final cached = await service.load();
      expect(cached.single.name, 'remote');
      expect(fetches, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('oversized market payloads are rejected', () {
    expect(
      () => parseSnippetMarket('x' * (256 * 1024 + 1)),
      throwsA(isA<FormatException>()),
    );
  });
}
