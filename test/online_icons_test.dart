import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/online_icons.dart';

void main() {
  test('online icon names build a validated Iconify PNG URL', () {
    final stored = onlineIconFromSearchResult('mdi:server');
    expect(stored, startsWith('url:https://api.iconify.design/mdi/server.png'));
    final parsed = onlineIconUrlFromStored(stored!);
    expect(parsed?.host, 'api.iconify.design');
    expect(parsed?.queryParameters['height'], '64');
  });

  test('stored icon URLs only allow https', () {
    expect(onlineIconUrlFromStored('url:https://example.com/a.png'), isNotNull);
    expect(onlineIconUrlFromStored('url:http://example.com/a.png'), isNull);
    expect(onlineIconUrlFromStored('url:file:///etc/passwd'), isNull);
    expect(onlineIconUrlFromStored('terminal'), isNull);
    expect(onlineIconFromSearchResult('not-a-name'), isNull);
    expect(onlineIconFromSearchResult('bad/../name'), isNull);
  });

  test('Iconify search results are filtered and bounded', () {
    final body = jsonEncode({
      'icons': [
        'mdi:server',
        'mdi:database',
        'bad',
        'mdi:server',
        'mdi:${'x' * 200}',
      ],
    });
    final entries = parseOnlineIconSearch(body);
    expect(entries.map((entry) => entry.name), ['mdi:server', 'mdi:database']);
    expect(
      () => parseOnlineIconSearch('{"icons":"bad"}'),
      throwsA(isA<FormatException>()),
    );
    expect(() => parseOnlineIconSearch('{}'), throwsA(isA<FormatException>()));
  });
}
