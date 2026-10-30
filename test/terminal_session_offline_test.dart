import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/terminal_session.dart';

void main() {
  test('offline session is ended and closes without a native connection', () async {
    final session = TerminalSession.offline(
      host: 'restored.example',
      username: 'restored',
      onEnded: () {},
    );
    expect(session.ended, isTrue);
    expect(session.title, 'restored@restored.example');
    session.send('ignored');
    await session.close();
  });
}
