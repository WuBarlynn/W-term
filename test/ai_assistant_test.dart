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

  test('stream accumulator merges content and tool-call fragments', () {
    final accumulator = AiStreamAccumulator();
    accumulator.addEvent({
      'choices': [
        {
          'delta': {'content': '检查中'},
        },
      ],
    });
    accumulator.addEvent({
      'choices': [
        {
          'delta': {'content': '…'},
        },
      ],
    });
    accumulator.addEvent({
      'choices': [
        {
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': 'call-1',
                'function': {'name': 'run_command', 'arguments': '{"comm'},
              },
            ],
          },
        },
      ],
    });
    accumulator.addEvent({
      'choices': [
        {
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': 'and":"uptime"}'},
              },
            ],
          },
        },
      ],
    });
    expect(accumulator.text, '检查中…');
    expect(accumulator.toolCalls.single.id, 'call-1');
    expect(accumulator.toolCalls.single.name, 'run_command');
    expect(
      accumulator.toolCalls.single.arguments.toString(),
      '{"command":"uptime"}',
    );
  });

  test('stream accumulator accepts a non-streaming message payload', () {
    final accumulator = AiStreamAccumulator();
    accumulator.addEvent({
      'choices': [
        {
          'message': {
            'content': '完成',
            'tool_calls': [
              {
                'id': 'call-2',
                'function': {
                  'name': 'run_command',
                  'arguments': '{"command":"df -h"}',
                },
              },
            ],
          },
        },
      ],
    });
    expect(accumulator.text, '完成');
    expect(
      accumulator.toolCalls.single.arguments.toString(),
      '{"command":"df -h"}',
    );
    expect(accumulator.toolCalls.single.toJson()['type'], 'function');
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
