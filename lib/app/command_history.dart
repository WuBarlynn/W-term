import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CommandHistoryEntry {
  final String command, host, username;
  final DateTime at;
  const CommandHistoryEntry({
    required this.command,
    required this.host,
    required this.username,
    required this.at,
  });

  Map<String, Object?> toJson() => {
    'command': command,
    'host': host,
    'username': username,
    'at': at.toUtc().toIso8601String(),
  };

  static CommandHistoryEntry? fromJson(Map<String, dynamic> value) {
    final command = value['command'];
    final host = value['host'];
    final username = value['username'];
    final at = DateTime.tryParse('${value['at'] ?? ''}');
    if (command is! String ||
        host is! String ||
        username is! String ||
        at == null ||
        command.trim().isEmpty) {
      return null;
    }
    return CommandHistoryEntry(
      command: command,
      host: host,
      username: username,
      at: at.toLocal(),
    );
  }
}

/// Turns raw terminal input into completed command lines. Escape sequences
/// (arrows, function keys) and control characters are ignored.
class CommandLineTracker {
  final _line = StringBuffer();
  bool _escape = false;

  List<String> feed(String text) {
    final completed = <String>[];
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (_escape) {
        if (RegExp(r'[A-Za-z~]').hasMatch(char)) _escape = false;
        continue;
      }
      if (rune == 0x1b) {
        _escape = true;
        continue;
      }
      if (rune == 0x0a || rune == 0x0d) {
        final line = _line.toString().trim();
        if (line.isNotEmpty) completed.add(line);
        _line.clear();
        continue;
      }
      if (rune == 0x7f || rune == 0x08) {
        final value = _line.toString();
        if (value.isNotEmpty) {
          _line
            ..clear()
            ..write(value.substring(0, value.length - 1));
        }
        continue;
      }
      if (rune < 0x20) continue;
      if (_line.length < 16 * 1024) _line.write(char);
    }
    return completed;
  }
}

class CommandHistory {
  final Future<File> Function() _file;
  final List<CommandHistoryEntry> entries = [];
  Future<void> _pending = Future.value();

  CommandHistory({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/command-history.json',
          ));

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map || value['version'] != 1 || value['entries'] is! List) {
        return;
      }
      entries
        ..clear()
        ..addAll(
          (value['entries'] as List)
              .whereType<Map>()
              .map(
                (row) => CommandHistoryEntry.fromJson(
                  Map<String, dynamic>.from(row),
                ),
              )
              .whereType<CommandHistoryEntry>(),
        );
      if (entries.length > 500) entries.removeRange(500, entries.length);
    } catch (_) {
      // History is optional and must never block the workspace.
    }
  }

  Future<void> record({
    required String command,
    required String host,
    required String username,
  }) {
    final line = command.trim();
    if (line.isEmpty) return Future.value();
    entries.insert(
      0,
      CommandHistoryEntry(
        command: line,
        host: host,
        username: username,
        at: DateTime.now(),
      ),
    );
    if (entries.length > 500) entries.removeRange(500, entries.length);
    return _save();
  }

  Future<void> clear() {
    entries.clear();
    return _save();
  }

  Future<void> _save() {
    _pending = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'entries': entries.map((entry) => entry.toJson()).toList(),
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    });
    return _pending;
  }
}
