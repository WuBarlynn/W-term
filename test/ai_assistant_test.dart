import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/ai_assistant.dart';

void main() {
  test('extracts one fenced command and ignores prose', () {
    expect(extractAiCommand('需要查看负载。\n```bash\nuptime\n```'), 'uptime');
    expect(extractAiCommand('没有命令'), isNull);
    expect(extractAiCommand('```\n\n```'), isNull);
  });

  test('read-only classifier refuses redirection and chaining', () {
    expect(isReadOnlyCommand('uptime'), isTrue);
    expect(isReadOnlyCommand('df -h /'), isTrue);
    expect(isReadOnlyCommand('docker ps'), isTrue);
    expect(isReadOnlyCommand('rm -rf /'), isFalse);
    expect(isReadOnlyCommand('cat /etc/passwd > /tmp/x'), isFalse);
    expect(isReadOnlyCommand('uptime && reboot'), isFalse);
    expect(isReadOnlyCommand('echo \$(whoami)'), isFalse);
  });

  test('AI settings round-trip permission and bounds', () {
    final settings = const AiSettings(
      baseUrl: 'https://example.com/v1',
      model: 'test-model',
      apiKey: 'secret',
      contextLines: 42,
      timeoutSeconds: 30,
      permission: AiPermission.readOnly,
    );
    final restored = AiSettings.fromJson(settings.toJson());
    expect(restored.baseUrl, 'https://example.com/v1');
    expect(restored.contextLines, 42);
    expect(restored.timeoutSeconds, 30);
    expect(restored.permission, AiPermission.readOnly);
    expect(restored.apiKey, 'secret');
  });
}
