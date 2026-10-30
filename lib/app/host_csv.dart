import 'host_store.dart';

List<List<String>> _records(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var index = 0;
  final text = input.replaceFirst('\ufeff', '');
  while (index < text.length) {
    final char = text[index];
    if (quoted) {
      if (char == '"') {
        if (index + 1 < text.length && text[index + 1] == '"') {
          field.write('"');
          index += 2;
          continue;
        }
        quoted = false;
        index++;
        continue;
      }
      field.write(char);
      index++;
      continue;
    }
    if (char == '"') {
      quoted = true;
      index++;
      continue;
    }
    if (char == ',' || char == '\t' || char == ';') {
      row.add(field.toString().trim());
      field.clear();
      index++;
      continue;
    }
    if (char == '\r' || char == '\n') {
      row.add(field.toString().trim());
      field.clear();
      if (row.any((value) => value.isNotEmpty)) rows.add(row);
      row = <String>[];
      if (char == '\r' && index + 1 < text.length && text[index + 1] == '\n') {
        index++;
      }
      index++;
      continue;
    }
    field.write(char);
    index++;
  }
  row.add(field.toString().trim());
  if (row.any((value) => value.isNotEmpty)) rows.add(row);
  return rows;
}

/// Imports a flat CSV/TSV list of hosts. Accepted headers (English or the
/// Chinese template aliases) are name, host, port, username, group and tags.
List<HostProfile> parseHostCsv(
  String input, {
  void Function(HostProfile host, String password)? onPassword,
}) {
  final rows = _records(input);
  if (rows.isEmpty) throw const FormatException('CSV 为空');
  final header = rows.first.map((value) => value.toLowerCase()).toList();
  final hasHeader =
      header.contains('host') ||
      header.contains('主机') ||
      header.contains('主机地址');
  int column(String name, List<String> aliases, int fallback) {
    for (final candidate in [name, ...aliases]) {
      final index = header.indexOf(candidate.toLowerCase());
      if (index >= 0) return index;
    }
    return fallback;
  }

  final nameAt = hasHeader ? column('name', ['名称'], 0) : 0;
  final hostAt = hasHeader ? column('host', ['主机', '主机地址'], 1) : 1;
  final portAt = hasHeader ? column('port', ['端口'], 2) : 2;
  final userAt = hasHeader ? column('username', ['用户', '用户名'], 3) : 3;
  final groupAt = hasHeader ? column('group', ['folder', '文件夹', '分类'], -1) : 4;
  final tagsAt = hasHeader ? column('tags', ['标签'], -1) : 5;
  final passwordAt = hasHeader ? column('password', ['passwd', '密码'], -1) : -1;
  final result = <HostProfile>[];
  for (var index = hasHeader ? 1 : 0; index < rows.length; index++) {
    final row = rows[index];
    String value(int at) => at >= 0 && at < row.length ? row[at].trim() : '';
    final host = value(hostAt);
    final username = value(userAt);
    if (host.isEmpty) throw FormatException('第 ${index + 1} 行缺少主机地址');
    if (username.isEmpty) throw FormatException('第 ${index + 1} 行缺少用户名');
    final port = int.tryParse(value(portAt));
    if (port != null && (port < 1 || port > 65535)) {
      throw FormatException('第 ${index + 1} 行端口无效');
    }
    final name = value(nameAt).isEmpty ? host : value(nameAt);
    final tags = value(tagsAt)
        .split(RegExp('[,;，；]'))
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
    final profile = HostProfile(
      id: HostProfile.newId(),
      name: name,
      host: host,
      port: port ?? 22,
      username: username,
      group: value(groupAt),
      tags: tags,
    );
    result.add(profile);
    final password = value(passwordAt);
    if (passwordAt >= 0 && password.isNotEmpty) {
      onPassword?.call(profile, password);
    }
  }
  if (result.isEmpty) throw const FormatException('CSV 没有可导入的主机');
  return result;
}
