import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

bool isIpv4(String value) {
  final parts = value.trim().split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
    final number = int.parse(part);
    if (number < 0 || number > 255) return false;
  }
  return true;
}

/// Selection-aware JSON detection for the terminal context menu. Scalars are
/// valid JSON but too easy to trigger by accident, so only objects/arrays are
/// offered for formatting.
bool isJsonText(String value) {
  final trimmed = value.trim();
  if (trimmed.length < 2) return false;
  final first = trimmed.codeUnitAt(0);
  if (first != 0x7B && first != 0x5B) return false;
  try {
    jsonDecode(trimmed);
    return true;
  } catch (_) {
    return false;
  }
}

class PluginSettings extends ChangeNotifier {
  final Future<File> Function() _file;
  bool jsonFormatter = true, ipLookup = true, filePreview = true;
  bool commandCompletion = true;
  bool taskNotifications = true;
  int notificationThresholdSeconds = 15;
  bool imeAutoEnglish = false;
  bool windowsHardwareInput = Platform.isWindows;
  bool linkUnderline = true;
  bool dragUpload = true;
  bool compactTabs = false;
  bool showFavoritesBar = true;
  bool clickTabLocates = false;
  bool restoreLayout = true;
  bool showStatusBar = true;
  bool rightClickPaste = false;
  bool showComposeBar = false;
  bool showSessionInfo = false;
  bool showMachineInfo = false;
  bool selectionPin = true;
  bool selectionSnippet = true;
  bool selectionShare = true;
  int maxUploadSizeMb = 0;
  bool loaded = false;

  PluginSettings({Future<File> Function()? file})
    : _file =
          file ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/plugins.json',
          ));

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final value = jsonDecode(await file.readAsString());
        if (value is Map) {
          jsonFormatter = value['jsonFormatter'] != false;
          ipLookup = value['ipLookup'] != false;
          filePreview = value['filePreview'] != false;
          commandCompletion = value['commandCompletion'] != false;
          taskNotifications = value['taskNotifications'] != false;
          final threshold = value['notificationThresholdSeconds'];
          notificationThresholdSeconds = threshold is int
              ? threshold.clamp(3, 3600)
              : 15;
          imeAutoEnglish = value['imeAutoEnglish'] == true;
          final hardwareInput = value['windowsHardwareInput'];
          windowsHardwareInput = hardwareInput is bool
              ? hardwareInput
              : Platform.isWindows;
          linkUnderline = value['linkUnderline'] != false;
          dragUpload = value['dragUpload'] != false;
          compactTabs = value['compactTabs'] == true;
          showFavoritesBar = value['showFavoritesBar'] != false;
          clickTabLocates = value['clickTabLocates'] == true;
          restoreLayout = value['restoreLayout'] != false;
          showStatusBar = value['showStatusBar'] != false;
          rightClickPaste = value['rightClickPaste'] == true;
          showComposeBar = value['showComposeBar'] == true;
          showSessionInfo = value['showSessionInfo'] == true;
          showMachineInfo = value['showMachineInfo'] == true;
          selectionPin = value['selectionPin'] != false;
          selectionSnippet = value['selectionSnippet'] != false;
          selectionShare = value['selectionShare'] != false;
          final maxUpload = value['maxUploadSizeMb'];
          maxUploadSizeMb = maxUpload is int ? maxUpload.clamp(0, 10240) : 0;
        }
      }
    } catch (_) {
      // Plugin preferences are optional.
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Map<String, Object?> toJson() => {
    'jsonFormatter': jsonFormatter,
    'ipLookup': ipLookup,
    'filePreview': filePreview,
    'commandCompletion': commandCompletion,
    'taskNotifications': taskNotifications,
    'notificationThresholdSeconds': notificationThresholdSeconds,
    'imeAutoEnglish': imeAutoEnglish,
    'windowsHardwareInput': windowsHardwareInput,
    'linkUnderline': linkUnderline,
    'dragUpload': dragUpload,
    'compactTabs': compactTabs,
    'showFavoritesBar': showFavoritesBar,
    'clickTabLocates': clickTabLocates,
    'restoreLayout': restoreLayout,
    'showStatusBar': showStatusBar,
    'rightClickPaste': rightClickPaste,
    'showComposeBar': showComposeBar,
    'showSessionInfo': showSessionInfo,
    'showMachineInfo': showMachineInfo,
    'selectionPin': selectionPin,
    'selectionSnippet': selectionSnippet,
    'selectionShare': selectionShare,
    'maxUploadSizeMb': maxUploadSizeMb,
  };

  Future<Map<String, Object?>> exportSynced() async => toJson();

  Future<void> applySynced(Object? data) async {
    if (data is! Map) return;
    final maxUpload = data['maxUploadSizeMb'];
    await save(
      json: data['jsonFormatter'] != false,
      ip: data['ipLookup'] != false,
      preview: data['filePreview'] != false,
      completion: data['commandCompletion'] != false,
      notifications: data['taskNotifications'] != false,
      notificationThresholdSecondsNext:
          data['notificationThresholdSeconds'] is int
          ? data['notificationThresholdSeconds'] as int
          : notificationThresholdSeconds,
      imeAutoEnglishNext: data['imeAutoEnglish'] == true,
      windowsHardwareInputNext: data['windowsHardwareInput'] is bool
          ? data['windowsHardwareInput'] as bool
          : windowsHardwareInput,
      linkUnderlineNext: data['linkUnderline'] != false,
      dragUploadNext: data['dragUpload'] != false,
      compactTabsNext: data['compactTabs'] == true,
      showFavoritesBarNext: data['showFavoritesBar'] != false,
      clickTabLocatesNext: data['clickTabLocates'] == true,
      restoreLayoutNext: data['restoreLayout'] != false,
      showStatusBarNext: data['showStatusBar'] != false,
      rightClickPasteNext: data['rightClickPaste'] == true,
      showComposeBarNext: data['showComposeBar'] == true,
      showSessionInfoNext: data['showSessionInfo'] == true,
      showMachineInfoNext: data['showMachineInfo'] == true,
      selectionPinNext: data['selectionPin'] != false,
      selectionSnippetNext: data['selectionSnippet'] != false,
      selectionShareNext: data['selectionShare'] != false,
      maxUploadSizeMbNext: maxUpload is int
          ? maxUpload.clamp(0, 10240)
          : maxUploadSizeMb,
    );
  }

  Future<void> save({
    required bool json,
    required bool ip,
    required bool preview,
    bool? completion,
    bool? notifications,
    int? notificationThresholdSecondsNext,
    bool? imeAutoEnglishNext,
    bool? windowsHardwareInputNext,
    bool? linkUnderlineNext,
    bool? dragUploadNext,
    bool? compactTabsNext,
    bool? showFavoritesBarNext,
    bool? clickTabLocatesNext,
    bool? restoreLayoutNext,
    bool? showStatusBarNext,
    bool? rightClickPasteNext,
    bool? showComposeBarNext,
    bool? showSessionInfoNext,
    bool? showMachineInfoNext,
    bool? selectionPinNext,
    bool? selectionSnippetNext,
    bool? selectionShareNext,
    int? maxUploadSizeMbNext,
  }) async {
    jsonFormatter = json;
    ipLookup = ip;
    filePreview = preview;
    commandCompletion = completion ?? commandCompletion;
    taskNotifications = notifications ?? taskNotifications;
    notificationThresholdSeconds =
        (notificationThresholdSecondsNext ?? notificationThresholdSeconds)
            .clamp(3, 3600);
    imeAutoEnglish = imeAutoEnglishNext ?? imeAutoEnglish;
    windowsHardwareInput = windowsHardwareInputNext ?? windowsHardwareInput;
    linkUnderline = linkUnderlineNext ?? linkUnderline;
    dragUpload = dragUploadNext ?? dragUpload;
    compactTabs = compactTabsNext ?? compactTabs;
    showFavoritesBar = showFavoritesBarNext ?? showFavoritesBar;
    clickTabLocates = clickTabLocatesNext ?? clickTabLocates;
    restoreLayout = restoreLayoutNext ?? restoreLayout;
    showStatusBar = showStatusBarNext ?? showStatusBar;
    rightClickPaste = rightClickPasteNext ?? rightClickPaste;
    showComposeBar = showComposeBarNext ?? showComposeBar;
    showSessionInfo = showSessionInfoNext ?? showSessionInfo;
    showMachineInfo = showMachineInfoNext ?? showMachineInfo;
    selectionPin = selectionPinNext ?? selectionPin;
    selectionSnippet = selectionSnippetNext ?? selectionSnippet;
    selectionShare = selectionShareNext ?? selectionShare;
    maxUploadSizeMb = (maxUploadSizeMbNext ?? maxUploadSizeMb).clamp(0, 10240);
    notifyListeners();
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'jsonFormatter': json,
        'ipLookup': ip,
        'filePreview': preview,
        'commandCompletion': commandCompletion,
        'taskNotifications': taskNotifications,
        'notificationThresholdSeconds': notificationThresholdSeconds,
        'imeAutoEnglish': imeAutoEnglish,
        'windowsHardwareInput': windowsHardwareInput,
        'linkUnderline': linkUnderline,
        'dragUpload': dragUpload,
        'compactTabs': compactTabs,
        'showFavoritesBar': showFavoritesBar,
        'clickTabLocates': clickTabLocates,
        'restoreLayout': restoreLayout,
        'showStatusBar': showStatusBar,
        'rightClickPaste': rightClickPaste,
        'showComposeBar': showComposeBar,
        'showSessionInfo': showSessionInfo,
        'showMachineInfo': showMachineInfo,
        'selectionPin': selectionPin,
        'selectionSnippet': selectionSnippet,
        'selectionShare': selectionShare,
        'maxUploadSizeMb': maxUploadSizeMb,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

final pluginSettings = PluginSettings();

bool uploadTooLarge(int bytes, int maxMb) =>
    maxMb > 0 && bytes > maxMb * 1024 * 1024;

class IpLookupResult {
  final String country, region, city, isp, org, timezone;
  final bool cached;
  final bool stale;
  const IpLookupResult({
    required this.country,
    required this.region,
    required this.city,
    required this.isp,
    required this.org,
    required this.timezone,
    this.cached = false,
    this.stale = false,
  });

  Map<String, Object?> toJson() => {
    'country': country,
    'region': region,
    'city': city,
    'isp': isp,
    'org': org,
    'timezone': timezone,
  };

  static IpLookupResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return IpLookupResult(
      country: '${raw['country'] ?? ''}',
      region: '${raw['region'] ?? ''}',
      city: '${raw['city'] ?? ''}',
      isp: '${raw['isp'] ?? ''}',
      org: '${raw['org'] ?? ''}',
      timezone: '${raw['timezone'] ?? ''}',
    );
  }

  IpLookupResult markCached({required bool stale}) => IpLookupResult(
    country: country,
    region: region,
    city: city,
    isp: isp,
    org: org,
    timezone: timezone,
    cached: true,
    stale: stale,
  );
}

/// Disk-backed IPv4 attribution cache. Fresh entries avoid the third-party
/// request; a stale entry is still useful when the network is unavailable.
class IpLookupCache {
  static const defaultTtl = Duration(hours: 24);
  static const defaultMaxEntries = 256;
  final Future<File> Function() _file;
  final DateTime Function() _now;
  final Duration ttl;
  final int maxEntries;
  Map<String, Map<String, Object?>>? _entries;

  IpLookupCache({
    Future<File> Function()? file,
    DateTime Function()? now,
    this.ttl = defaultTtl,
    this.maxEntries = defaultMaxEntries,
  }) : _file =
           file ??
           (() async => File(
             '${(await getApplicationSupportDirectory()).path}/ip-lookup-cache.json',
           )),
       _now = now ?? DateTime.now;

  Future<Map<String, Map<String, Object?>>> _load() async {
    final loaded = _entries;
    if (loaded != null) return loaded;
    final entries = <String, Map<String, Object?>>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final value = jsonDecode(await file.readAsString());
        if (value is Map && value['entries'] is Map) {
          for (final item in (value['entries'] as Map).entries) {
            final key = '${item.key}';
            final raw = item.value;
            if (key.isEmpty || raw is! Map) continue;
            entries[key] = Map<String, Object?>.from(raw);
          }
        }
      }
    } catch (_) {
      // A corrupt or unreadable cache must never block a new lookup.
    }
    return _entries = entries;
  }

  Future<IpLookupResult?> read(String ip, {bool includeStale = false}) async {
    if (!isIpv4(ip)) return null;
    final entries = await _load();
    final entry = entries[ip.trim()];
    if (entry == null) return null;
    final cachedAt = DateTime.tryParse('${entry['cachedAt'] ?? ''}');
    if (cachedAt == null) return null;
    final age = _now().difference(cachedAt);
    final fresh = !age.isNegative && age <= ttl;
    if (!fresh && !includeStale) return null;
    final result = IpLookupResult.fromJson(entry['result']);
    return result?.markCached(stale: !fresh);
  }

  Future<void> write(String ip, IpLookupResult result) async {
    if (!isIpv4(ip)) return;
    final entries = await _load();
    final key = ip.trim();
    entries[key] = {
      'cachedAt': _now().toUtc().toIso8601String(),
      'result': result.toJson(),
    };
    if (entries.length > maxEntries) {
      final ordered = entries.entries.toList()
        ..sort((a, b) {
          final left = '${a.value['cachedAt'] ?? ''}';
          final right = '${b.value['cachedAt'] ?? ''}';
          return left.compareTo(right);
        });
      for (final entry in ordered.take(entries.length - maxEntries)) {
        entries.remove(entry.key);
      }
    }
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'version': 1, 'entries': entries}),
        flush: true,
      );
    } catch (_) {
      // Keep the in-memory cache even when the support directory is read-only.
    }
  }

  Future<void> clear() async {
    _entries = {};
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The cache is optional state.
    }
  }
}

final defaultIpLookupCache = IpLookupCache();

Future<IpLookupResult> lookupIp(String ip, {IpLookupCache? cache}) async {
  if (!isIpv4(ip)) throw const FormatException('请选择有效的 IPv4 地址');
  final normalized = ip.trim();
  final cached = await cache?.read(normalized);
  if (cached != null) return cached;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(Uri.parse('https://ipwho.is/$normalized'))
        .timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('IP 查询接口返回 ${response.statusCode}');
    }
    final value = jsonDecode(body);
    if (value is! Map || value['success'] == false) {
      throw StateError('${value is Map ? value['message'] : 'IP 查询失败'}');
    }
    final connection = value['connection'] is Map
        ? value['connection'] as Map
        : const {};
    final timezone = value['timezone'] is Map
        ? value['timezone'] as Map
        : const {};
    final result = IpLookupResult(
      country: '${value['country'] ?? ''}',
      region: '${value['region'] ?? ''}',
      city: '${value['city'] ?? ''}',
      isp: '${connection['isp'] ?? ''}',
      org: '${connection['org'] ?? ''}',
      timezone: '${timezone['id'] ?? ''}',
    );
    if (cache != null) {
      try {
        await cache.write(normalized, result);
      } catch (_) {
        /* The lookup result is still usable without persistence. */
      }
    }
    return result;
  } catch (_) {
    final stale = await cache?.read(normalized, includeStale: true);
    if (stale != null) return stale;
    rethrow;
  } finally {
    client.close(force: true);
  }
}

bool isSystemPreviewPath(String path) {
  final lower = path.toLowerCase();
  return const [
    '.pdf',
    '.mp4',
    '.mov',
    '.m4v',
    '.webm',
    '.mp3',
    '.m4a',
    '.wav',
    '.flac',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
  ].any(lower.endsWith);
}

bool isImagePath(String path) {
  final lower = path.toLowerCase().split('?').first;
  return const [
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  ].any(lower.endsWith);
}

String? resolveRemotePath(String selected, String? cwd) {
  var value = selected.trim();
  if (value.isEmpty || value.contains('\n')) return null;
  if ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))) {
    value = value.substring(1, value.length - 1);
  }
  if (value.startsWith('/')) return value;
  if (cwd == null || cwd.isEmpty) return null;
  return '${cwd.replaceAll(RegExp(r'/+$'), '')}/$value';
}
