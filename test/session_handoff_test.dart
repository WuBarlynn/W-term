import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/session_handoff.dart';

void main() {
  test('handoff payload round-trips every field', () {
    const payload = SessionHandoffPayload(
      connectionId: 'c-1',
      host: 'example.com',
      username: 'alice',
      hostId: 'host-1',
      snapshot: 'line 1\nline "2"',
      title: 'alice@example.com',
    );
    final decoded = SessionHandoffPayload.decode(payload.encode());
    expect(decoded, isNotNull);
    expect(decoded!.connectionId, 'c-1');
    expect(decoded.host, 'example.com');
    expect(decoded.username, 'alice');
    expect(decoded.hostId, 'host-1');
    expect(decoded.snapshot, 'line 1\nline "2"');
    expect(decoded.title, 'alice@example.com');
  });

  test('handoff payload rejects missing or malformed fields', () {
    expect(SessionHandoffPayload.decode(null), isNull);
    expect(SessionHandoffPayload.decode(''), isNull);
    expect(SessionHandoffPayload.decode('{broken'), isNull);
    expect(SessionHandoffPayload.decode('{"connectionId":"c"}'), isNull);
    expect(
      SessionHandoffPayload.decode('{"connectionId":"c","host":"h"}')?.hostId,
      '',
    );
  });
}
