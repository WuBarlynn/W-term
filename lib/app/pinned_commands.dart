import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class PinnedCommand {
  final String name, command, hostId, tag;
  const PinnedCommand({
    required this.name,
    required this.command,
    this.hostId = '',
    this.tag = '',
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'command': command,
    if (hostId.isNotEmpty) 'hostId': hostId,
    if (tag.isNotEmpty) 'tag': tag,
  };

  static PinnedCommand? fromJson(Map<String, dynamic> value) {
    final name = value['name'];
    final command = value['command'];
    if (name is! String || command is! String || command.trim().isEmpty) {
      return null;
    }
    return PinnedCommand(
      name: name,
      command: command,
      hostId: value['hostId'] is String ? value['hostId'] as String : '',
      tag: value['tag'] is String ? value['tag'] as String : '',
    );
  }
}

class PinnedCommands extends ChangeNotifier {
  final Future<File> Function() _file;
  final List<PinnedCommand> entries = [];
  Future<void> _pending = Future.value();
  bool loaded = false;

  PinnedCommands({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/pinned-commands.json',
          ));

  List<PinnedCommand> forHost(
    String hostId, {
    Iterable<String> tags = const [],
  }) {
    final hostTags = tags.toSet();
    return entries
        .where(
          (entry) => entry.tag.isNotEmpty
              ? hostTags.contains(entry.tag)
              : entry.hostId.isEmpty || entry.hostId == hostId,
        )
        .toList();
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final value = jsonDecode(await file.readAsString());
        if (value is Map && value['entries'] is List) {
          entries
            ..clear()
            ..addAll(
              (value['entries'] as List)
                  .whereType<Map>()
                  .map(
                    (row) =>
                        PinnedCommand.fromJson(Map<String, dynamic>.from(row)),
                  )
                  .whereType<PinnedCommand>(),
            );
        }
      }
    } catch (_) {
      // A broken pin file must not block terminals.
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  Future<Map<String, Object?>> exportSynced() async {
    await _pending.catchError((Object _) {});
    return toJson();
  }

  Future<void> applySynced(Object? data) async {
    if (data is! Map || data['entries'] is! List) return;
    final next = (data['entries'] as List)
        .whereType<Map>()
        .map((row) => PinnedCommand.fromJson(Map<String, dynamic>.from(row)))
        .whereType<PinnedCommand>()
        .take(50)
        .toList();
    entries
      ..clear()
      ..addAll(next);
    notifyListeners();
    await _save();
  }

  Future<void> pin(PinnedCommand command) {
    final exists = entries.any(
      (entry) =>
          entry.command == command.command &&
          entry.hostId == command.hostId &&
          entry.tag == command.tag &&
          entry.name == command.name,
    );
    if (!exists) entries.insert(0, command);
    if (entries.length > 50) entries.removeRange(50, entries.length);
    notifyListeners();
    return _save();
  }

  Future<void> unpin(PinnedCommand command) {
    entries.removeWhere(
      (entry) =>
          entry.command == command.command &&
          entry.hostId == command.hostId &&
          entry.tag == command.tag &&
          entry.name == command.name,
    );
    notifyListeners();
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

final pinnedCommands = PinnedCommands();
