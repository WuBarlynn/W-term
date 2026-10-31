import 'dart:convert';

import 'keyword_highlights.dart';
import 'pinned_commands.dart';
import 'plugins.dart';
import 'terminal_appearance.dart';

/// Aggregates device preferences that travel through the encrypted GitHub
/// sync snapshot. Device-local security and session state stay out.
class SyncedSettings {
  static Future<String> export() async => jsonEncode({
    'version': 1,
    'appearance': await terminalAppearance.exportSynced(),
    'plugins': await pluginSettings.exportSynced(),
    'pinned': await pinnedCommands.exportSynced(),
    'highlights': await keywordHighlights.exportSynced(),
  });

  static Future<void> import(String json) async {
    final value = jsonDecode(json);
    if (value is! Map || value['version'] != 1) return;
    await terminalAppearance.applySynced(value['appearance']);
    await pluginSettings.applySynced(value['plugins']);
    await pinnedCommands.applySynced(value['pinned']);
    await keywordHighlights.applySynced(value['highlights']);
  }
}
