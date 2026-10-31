import 'dart:convert';

class CommandSnippet {
  final String id, name, command;
  final List<String> tags;
  const CommandSnippet(
    this.id,
    this.name,
    this.command, {
    this.tags = const [],
  });
}

String? validateSnippetCommand(String value) {
  if (value.trim().isEmpty ||
      utf8.encode(value).length > 16384 ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
    return '请输入不含换行或控制字符的单行命令（最多 16 KiB）';
  }
  return null;
}

abstract interface class SnippetStore {
  Future<List<CommandSnippet>> readSnippets();
  Future<void> saveSnippet(
    String id,
    String name,
    String command, {
    List<String> tags = const [],
  });
  Future<void> deleteSnippet(String id);
}
