import 'dart:convert';

import 'ai_assistant.dart';
import 'keyword_highlights.dart';
import 'pinned_commands.dart';
import 'plugins.dart';
import 'terminal_appearance.dart';

/// Aggregates device preferences that travel through the encrypted GitHub
/// sync snapshot. Device-local security and session state stay out.
class SyncedAiCodec {
  static Map<String, Object?> encode(AiProfileSet set) => {
    'activeId': set.activeId,
    'profiles': set.profiles.map((profile) => profile.toJson()).toList(),
  };

  static AiProfileSet? decode(Object? raw) {
    if (raw is! Map || raw['profiles'] is! List) return null;
    final profiles = (raw['profiles'] as List)
        .whereType<Map>()
        .map((row) => AiProfile.fromJson(Map<String, dynamic>.from(row)))
        .whereType<AiProfile>()
        .toList();
    if (profiles.isEmpty) return null;
    final requested = raw['activeId'];
    final active = requested is String &&
            profiles.any((profile) => profile.id == requested)
        ? requested
        : profiles.first.id;
    return AiProfileSet(profiles: profiles, activeId: active);
  }
}

class SyncedSettings {
  static Future<String> export() async {
    Map<String, Object?>? ai;
    try {
      ai = SyncedAiCodec.encode(await const AiStore().loadProfiles());
    } catch (_) {
      // A denied keychain read must not block syncing the remaining settings.
    }
    return jsonEncode({
      'version': 1,
      'appearance': await terminalAppearance.exportSynced(),
      'plugins': await pluginSettings.exportSynced(),
      'pinned': await pinnedCommands.exportSynced(),
      'highlights': await keywordHighlights.exportSynced(),
      'ai': ?ai,
    });
  }

  static Future<void> import(String json) async {
    final value = jsonDecode(json);
    if (value is! Map || value['version'] != 1) return;
    await terminalAppearance.applySynced(value['appearance']);
    await pluginSettings.applySynced(value['plugins']);
    await pinnedCommands.applySynced(value['pinned']);
    await keywordHighlights.applySynced(value['highlights']);
    final ai = SyncedAiCodec.decode(value['ai']);
    if (ai != null) await const AiStore().saveProfiles(ai);
  }
}
