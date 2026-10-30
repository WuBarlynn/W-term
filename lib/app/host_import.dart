import 'dart:convert';
import 'dart:typed_data';

import 'host_csv.dart';
import 'host_store.dart';
import 'xlsx_import.dart';
import 'zip_reader.dart';

class HostImportBundle {
  final List<HostProfile> hosts;
  final Map<String, String> passwords;
  const HostImportBundle({required this.hosts, this.passwords = const {}});
}

/// Imports the text formats that can be read without a platform SDK:
/// CSV/TSV, PuTTY registry exports, and SecureCRT/MobaXterm INI exports.
List<HostProfile> parseHostImport(
  String fileName,
  String content, {
  void Function(HostProfile host, String password)? onPassword,
}) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.reg')) return parsePuttyRegistry(content);
  if (lower.endsWith('.xsh') || content.contains('[XSH SESSION]')) {
    return parseXshellSessions(content);
  }
  if (lower.endsWith('.ini') || lower.endsWith('.mxtsessions')) {
    final parsed = parseIniSessions(content);
    if (parsed.isNotEmpty) return parsed;
  }
  return parseHostCsv(content, onPassword: onPassword);
}

HostImportBundle parseHostImportBundle(String fileName, String content) {
  final passwords = <String, String>{};
  final hosts = parseHostImport(
    fileName,
    content,
    onPassword: (host, password) => passwords[host.id] = password,
  );
  return HostImportBundle(hosts: hosts, passwords: passwords);
}

HostImportBundle parseHostImportBytesBundle(String fileName, Uint8List bytes) {
  final passwords = <String, String>{};
  final hosts = parseHostImportBytes(
    fileName,
    bytes,
    onPassword: (host, password) => passwords[host.id] = password,
  );
  return HostImportBundle(hosts: hosts, passwords: passwords);
}

String _unquote(String value) {
  var result = value.trim();
  if (result.length >= 2 &&
      ((result.startsWith('"') && result.endsWith('"')) ||
          (result.startsWith("'") && result.endsWith("'")))) {
    result = result.substring(1, result.length - 1);
  }
  return result.replaceAll(r'\"', '"');
}

int? _port(String value) {
  final parsed = int.tryParse(_unquote(value));
  return parsed == null || parsed < 1 || parsed > 65535 ? null : parsed;
}

List<HostProfile> parsePuttyRegistry(String content) {
  final hosts = <HostProfile>[];
  String? section;
  final values = <String, String>{};
  void flush() {
    final name = section;
    final host = values['HostName'];
    final username = values['UserName'];
    if (name != null && host != null && host.isNotEmpty && username != null) {
      final port = values['PortNumber']?.toLowerCase();
      final parsedPort = port != null && port.startsWith('dword:')
          ? int.tryParse(port.substring(6), radix: 16)
          : int.tryParse(port ?? '');
      hosts.add(
        HostProfile(
          id: HostProfile.newId(),
          name: name.isEmpty ? host : name,
          host: host,
          port: parsedPort ?? 22,
          username: username,
        ),
      );
    }
    values.clear();
  }

  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      flush();
      section = null;
      final key = line.substring(1, line.length - 1);
      final marker = RegExp(r'Sessions\\(.+)$').firstMatch(key);
      if (marker != null) section = marker.group(1)!.replaceAll(r'\\', r'\');
      continue;
    }
    final match = RegExp(r'^"([^"]+)"\s*=\s*(.+)$').firstMatch(line);
    if (match != null && section != null) {
      values[match.group(1)!] = _unquote(match.group(2)!);
    }
  }
  flush();
  if (hosts.isEmpty) throw const FormatException('没有找到 PuTTY SSH 会话');
  return hosts;
}

List<HostProfile> parseIniSessions(String content) {
  final hosts = <HostProfile>[];
  String? section;
  final values = <String, String>{};
  void flush() {
    final rawSection = section;
    if (rawSection == null) return;
    final current = rawSection.split(RegExp(r'[:\\]')).last.trim();
    final raw = values['session'] ?? '';
    if (raw.startsWith('#109#0%')) {
      final fields = raw.substring(7).split('%');
      if (fields.length >= 3 && fields[0].isNotEmpty) {
        final port = int.tryParse(fields[1]);
        hosts.add(
          HostProfile(
            id: HostProfile.newId(),
            name: current.isEmpty ? fields[0] : current,
            host: fields[0],
            port: port == null || port < 1 || port > 65535 ? 22 : port,
            username: fields[2],
            group: values['subrep'] ?? '',
          ),
        );
      }
    } else {
      final host = values['hostname'] ?? values['host'];
      final username = values['username'] ?? values['user'];
      final protocol = (values['protocol'] ?? 'ssh').toLowerCase();
      if (host != null &&
          host.isNotEmpty &&
          username != null &&
          username.isNotEmpty &&
          protocol.contains('ssh')) {
        hosts.add(
          HostProfile(
            id: HostProfile.newId(),
            name: current.isEmpty ? host : current,
            host: host,
            port: _port(values['port'] ?? '') ?? 22,
            username: username,
            group: values['folder'] ?? values['subrep'] ?? '',
          ),
        );
      }
    }
    values.clear();
  }

  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      flush();
      section = line.substring(1, line.length - 1).trim();
      continue;
    }
    final equal = line.indexOf('=');
    if (equal <= 0 || section == null) continue;
    final key = line.substring(0, equal).trim();
    final value = line.substring(equal + 1).trim();
    if (value.startsWith('#109#0%')) {
      flush();
      section = key;
      values['session'] = value;
      continue;
    }
    if (key.toLowerCase() == 'd:"hostname"') {
      values['hostname'] = _unquote(value);
    }
    if (key.toLowerCase() == 'd:"username"') {
      values['username'] = _unquote(value);
    }
    if (key.toLowerCase() == 'd:"port"') {
      values['port'] = value.toLowerCase().startsWith('dword:')
          ? '${int.tryParse(value.substring(6), radix: 16) ?? 0}'
          : _unquote(value);
    }
    values[key.toLowerCase()] = _unquote(value);
    if (key.contains('\\')) {
      final leaf = key.split('\\').last.replaceAll('"', '').toLowerCase();
      values[leaf] = _unquote(value);
    }
  }
  flush();
  if (hosts.isEmpty) throw const FormatException('没有找到 INI 中的 SSH 会话');
  return hosts;
}

/// Imports Xshell's `.xsh` session or a `.xts` backup archive. Passwords in
/// Xshell files are encrypted per-installation and are intentionally ignored.
List<HostProfile> parseHostImportBytes(
  String fileName,
  Uint8List bytes, {
  void Function(HostProfile host, String password)? onPassword,
}) {
  final lower = fileName.toLowerCase();
  final looksLikeZip =
      bytes.length > 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;
  if (lower.endsWith('.xlsx')) return parseHostXlsx(fileName, bytes);
  if (lower.endsWith('.xts') || looksLikeZip) {
    final entries = readZipEntries(bytes);
    if (entries.keys.any(
      (name) => name.startsWith('xl/worksheets/') && name.endsWith('.xml'),
    )) {
      return parseHostXlsx(fileName, bytes);
    }
    final hosts = <HostProfile>[];
    for (final entry in entries.entries) {
      if (!entry.key.toLowerCase().endsWith('.xsh')) continue;
      final name = entry.key.split('/').last;
      final stem = name.endsWith('.xsh')
          ? name.substring(0, name.length - 4)
          : name;
      final group = entry.key.contains('/')
          ? entry.key.substring(0, entry.key.lastIndexOf('/'))
          : '';
      try {
        hosts.addAll(
          parseXshellSessions(
            utf8.decode(entry.value, allowMalformed: true),
            fallbackName: stem,
            group: group,
          ),
        );
      } on FormatException {
        // Skip unrelated entries inside the backup.
      }
    }
    if (hosts.isEmpty) {
      throw const FormatException('XTS 中没有找到可导入的 Xshell SSH 会话');
    }
    return hosts;
  }
  if (lower.endsWith('.xsh')) {
    return parseXshellSessions(
      utf8.decode(bytes, allowMalformed: true),
      fallbackName: fileName
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll(RegExp(r'\.xsh$', caseSensitive: false), ''),
    );
  }
  return parseHostImport(fileName, utf8.decode(bytes, allowMalformed: true));
}

List<HostProfile> parseXshellSessions(
  String content, {
  String fallbackName = '',
  String group = '',
}) {
  final sections = <String, Map<String, String>>{};
  String? current;
  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1).trim().toUpperCase();
      sections.putIfAbsent(current, () => {});
      continue;
    }
    final equal = line.indexOf('=');
    if (equal <= 0 || current == null) continue;
    sections[current]![line.substring(0, equal).trim()] = line
        .substring(equal + 1)
        .trim();
  }
  final hosts = <HostProfile>[];
  for (final section in sections.entries) {
    if (!section.key.contains('CONNECTION')) continue;
    final values = section.value;
    final protocol = (values['Protocol'] ?? 'SSH').toUpperCase();
    if (!protocol.contains('SSH')) continue;
    final host = values['Host'] ?? values['HostName'];
    final username = values['UserName'] ?? values['User'] ?? values['Username'];
    if (host == null || host.isEmpty || username == null || username.isEmpty) {
      continue;
    }
    final port = int.tryParse(values['Port'] ?? '');
    if (port != null && (port < 1 || port > 65535)) continue;
    final name = values['Name'] ?? values['SessionName'] ?? fallbackName;
    final folder = values['Folder'] ?? values['Path'] ?? group;
    hosts.add(
      HostProfile(
        id: HostProfile.newId(),
        name: name.isEmpty ? host : name,
        host: host,
        port: port ?? 22,
        username: username,
        group: folder,
      ),
    );
  }
  if (hosts.isEmpty) {
    throw const FormatException('没有找到 Xshell SSH 会话');
  }
  return hosts;
}
