import 'host_store.dart';

class SshImportEntry {
  final String alias, hostname, username;
  final int port;
  final List<String> issues, identityFiles;
  const SshImportEntry(
    this.alias,
    this.hostname,
    this.username,
    this.port,
    this.issues,
    this.identityFiles,
  );
  bool get canImport => issues.isEmpty;
  HostProfile profile() => HostProfile(
    id: HostProfile.newId(),
    name: alias,
    host: hostname,
    username: username,
    port: port,
    group: 'OpenSSH 导入',
  );
}

class _Directive {
  final List<String> patterns, values;
  final String key;
  _Directive(this.patterns, this.key, this.values);
}

List<String> _words(String line, int number) {
  final result = <String>[];
  var value = '', quoted = false, started = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '\\') throw FormatException('第 $number 行：暂不支持反斜杠转义或续行，请使用双引号');
    if (c == '"') {
      quoted = !quoted;
      started = true;
      continue;
    }
    if (c == '#' && !quoted) break;
    if (c.trim().isEmpty && !quoted) {
      if (started) {
        result.add(value);
        value = '';
        started = false;
      }
    } else {
      value += c;
      started = true;
    }
  }
  if (quoted) throw FormatException('第 $number 行：双引号未闭合');
  if (started) result.add(value);
  return result;
}

// Bounded glob matching without regex backtracking; arguments remain case-sensitive.
bool _glob(String pattern, String value) {
  var p = 0, v = 0, star = -1, mark = 0;
  while (v < value.length) {
    if (p < pattern.length && (pattern[p] == '?' || pattern[p] == value[v])) {
      p++;
      v++;
    } else if (p < pattern.length && pattern[p] == '*') {
      star = p++;
      mark = v;
    } else if (star >= 0) {
      p = star + 1;
      v = ++mark;
    } else {
      return false;
    }
  }
  while (p < pattern.length && pattern[p] == '*') {
    p++;
  }
  return p == pattern.length;
}

bool _matches(List<String> patterns, String alias) =>
    !patterns.any((p) => p.startsWith('!') && _glob(p.substring(1), alias)) &&
    patterns.any((p) => !p.startsWith('!') && _glob(p, alias));

/// A deliberately limited importer. Never executes commands or resolves Includes.
List<SshImportEntry> parseOpenSshConfig(
  String source, {
  String defaultUsername = '',
}) {
  if (source.length > 65536 || source.contains('\x00')) {
    throw const FormatException('配置过大或含无效字符（最多 64 KiB）');
  }
  final directives = <_Directive>[];
  final aliases = <String>{};
  var patterns = <String>['*'];
  final lines = source.replaceFirst('\ufeff', '').split('\n');
  if (lines.length > 2000) throw const FormatException('配置最多支持 2000 行');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = RegExp(r'^([a-zA-Z][a-zA-Z0-9]*)(?:\s*=\s*|\s+)(.*)$')
        .firstMatch(line);
    if (match == null) throw FormatException('第 ${i + 1} 行：无法解析配置');
    final key = match[1]!.toLowerCase(), values = _words(match[2]!, i + 1);
    if (values.isEmpty) throw FormatException('第 ${i + 1} 行：缺少配置值');
    if (key == 'include' || key == 'match') {
      throw FormatException(
        '第 ${i + 1} 行：暂不支持 $key，请先提供不含 Include/Match 的独立配置',
      );
    }
    if (key == 'host') {
      if (values.any(
        (p) => p.isEmpty || p.length > 256 || p.contains(RegExp(r'\s')),
      )) {
        throw FormatException('第 ${i + 1} 行：Host 名称无效');
      }
      patterns = values;
      aliases.addAll(
        values.where((p) => !p.startsWith('!') && !p.contains(RegExp(r'[*?]'))),
      );
      if (aliases.length > 500) throw const FormatException('一次最多导入 500 个主机');
    } else {
      directives.add(_Directive(patterns, key, values));
    }
  }
  return aliases.map((alias) {
    final options = <String, String>{};
    final issues = <String>{}, keys = <String>[];
    for (final d in directives.where((d) => _matches(d.patterns, alias))) {
      if (d.key == 'identityfile') {
        keys.add(d.values.join(' '));
        continue;
      }
      if (!['hostname', 'user', 'port'].contains(d.key)) {
        issues.add('暂不支持 ${d.key}');
        continue;
      }
      if (d.values.length != 1) {
        issues.add('${d.key} 必须只有一个值');
        continue;
      }
      options.putIfAbsent(d.key, () => d.values.single);
    }
    final host = options['hostname'] ?? alias;
    final user = options['user'] ?? defaultUsername.trim();
    final port = int.tryParse(options['port'] ?? '22') ?? 0;
    if (host.isEmpty || host.contains(RegExp(r'[\s/%$@]'))) {
      issues.add('地址为空或含未支持的替换符/字符');
    }
    if (user.isEmpty || user.contains(RegExp(r'[\s/%$]'))) {
      issues.add('请填写默认用户名或有效的 User');
    }
    if (port < 1 || port > 65535) issues.add('端口必须在 1–65535 之间');
    return SshImportEntry(alias, host, user, port, issues.toList(), keys);
  }).toList();
}

Future<int> importSshEntries(
  HostStore store,
  List<SshImportEntry> entries,
) async {
  if (entries.any((e) => !e.canImport)) {
    throw const FormatException('存在不可导入的配置');
  }
  final existing = await store.read();
  final next = [...existing];
  var added = 0;
  for (final e in entries) {
    if (next.any(
      (h) =>
          h.name == e.alias &&
          h.host == e.hostname &&
          h.port == e.port &&
          h.username == e.username,
    )) {
      continue;
    }
    next.add(e.profile());
    added++;
  }
  if (added > 0) await store.write(next);
  return added;
}
