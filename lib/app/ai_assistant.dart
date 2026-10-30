import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AiPermission { ask, readOnly, full }

class AiSettings {
  final String baseUrl, model, apiKey, systemPrompt;
  final int contextLines, timeoutSeconds;
  final AiPermission permission;
  const AiSettings({
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.apiKey = '',
    this.contextLines = 120,
    this.timeoutSeconds = 60,
    this.permission = AiPermission.ask,
    this.systemPrompt =
        '你是 W Term 的终端运维助手。回答要简洁、可执行。'
        '如果确实需要执行一条命令，请把命令放在唯一的 ```bash 代码块中；'
        '不要编造服务器状态，信息不足时先说明需要什么。',
  });

  AiSettings copyWith({
    String? baseUrl,
    String? model,
    String? apiKey,
    String? systemPrompt,
    int? contextLines,
    int? timeoutSeconds,
    AiPermission? permission,
  }) => AiSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    contextLines: contextLines ?? this.contextLines,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    permission: permission ?? this.permission,
  );

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
    'systemPrompt': systemPrompt,
    'contextLines': contextLines,
    'timeoutSeconds': timeoutSeconds,
    'permission': permission.name,
  };

  static AiSettings fromJson(Map<String, dynamic> value) {
    AiPermission permission = AiPermission.ask;
    for (final candidate in AiPermission.values) {
      if (candidate.name == value['permission']) permission = candidate;
    }
    int positive(Object? raw, int fallback, int max) {
      final number = raw is int ? raw : int.tryParse('$raw');
      return number == null ? fallback : number.clamp(1, max);
    }

    return AiSettings(
      baseUrl: '${value['baseUrl'] ?? 'https://api.openai.com/v1'}'.trim(),
      model: '${value['model'] ?? 'gpt-4o-mini'}'.trim(),
      apiKey: '${value['apiKey'] ?? ''}',
      systemPrompt:
          '${value['systemPrompt'] ?? const AiSettings().systemPrompt}',
      contextLines: positive(value['contextLines'], 120, 1000),
      timeoutSeconds: positive(value['timeoutSeconds'], 60, 300),
      permission: permission,
    );
  }
}

class AiStore {
  static const _key = 'wterm.ai-settings.v1';
  final FlutterSecureStorage storage;
  const AiStore({
    this.storage = const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
    ),
  });

  Future<AiSettings> load() async {
    final raw = await storage.read(key: _key);
    if (raw == null) return const AiSettings();
    try {
      final value = jsonDecode(raw);
      return value is Map
          ? AiSettings.fromJson(Map<String, dynamic>.from(value))
          : const AiSettings();
    } catch (_) {
      return const AiSettings();
    }
  }

  Future<void> save(AiSettings settings) =>
      storage.write(key: _key, value: jsonEncode(settings.toJson()));
}

class AiReply {
  final String text;
  final String? command;
  const AiReply(this.text, this.command);
}

String? extractAiCommand(String text) {
  final match = RegExp(
    r'```(?:bash|sh|shell|zsh)?\s*\n([\s\S]*?)```',
    caseSensitive: false,
  ).firstMatch(text);
  final command = match?.group(1)?.trim();
  return command == null || command.isEmpty ? null : command;
}

bool isReadOnlyCommand(String command) {
  final value = command.trim();
  if (value.isEmpty) return false;
  if (RegExp(r'(^|[^<])>|<\(|\$\(|`|&&|\|\||;').hasMatch(value)) {
    return false;
  }
  const allowed = [
    'uptime',
    'free',
    'df',
    'du',
    'ls',
    'cat',
    'head',
    'tail',
    'grep',
    'ps',
    'ss',
    'netstat',
    'uname',
    'whoami',
    'hostname',
    'id',
    'date',
    'top -bn1',
    'vm_stat',
    'systemctl status',
    'journalctl',
    'docker ps',
    'docker images',
    'tmux list-sessions',
    'ip addr',
    'ip route',
  ];
  return allowed.any(
    (prefix) => value == prefix || value.startsWith('$prefix '),
  );
}

class AiService {
  final AiSettings settings;
  final List<(String, String)> history;
  const AiService({required this.settings, this.history = const []});

  Future<AiReply> ask({
    required String question,
    required String context,
  }) async {
    if (settings.apiKey.trim().isEmpty) {
      throw StateError('请先在 AI 设置中填写 API Key');
    }
    final base = settings.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(
      base.endsWith('/chat/completions') ? base : '$base/chat/completions',
    );
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw StateError('AI 接口地址必须为 http 或 https URL');
    }
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': settings.systemPrompt},
      {
        'role': 'user',
        'content': '当前终端最近输出：\n```\n$context\n```\n\n用户问题：$question',
      },
      for (final (role, content) in history) {'role': role, 'content': content},
    ];
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: settings.timeoutSeconds);
    try {
      final request = await client
          .postUrl(uri)
          .timeout(Duration(seconds: settings.timeoutSeconds));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer ${settings.apiKey}');
      request.write(
        jsonEncode({
          'model': settings.model,
          'messages': messages,
          'temperature': 0.2,
        }),
      );
      final response = await request.close().timeout(
        Duration(seconds: settings.timeoutSeconds),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final preview = body.substring(0, body.length.clamp(0, 400));
        throw StateError('AI 接口返回 ${response.statusCode}：$preview');
      }
      final decoded = jsonDecode(body);
      final choices = decoded is Map ? decoded['choices'] : null;
      final message = choices is List && choices.isNotEmpty
          ? (choices.first as Map)['message']
          : null;
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw StateError('AI 接口没有返回内容');
      }
      return AiReply(content.trim(), extractAiCommand(content));
    } finally {
      client.close(force: true);
    }
  }
}
