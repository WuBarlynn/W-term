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

class PluginSettings extends ChangeNotifier {
  final Future<File> Function() _file;
  bool jsonFormatter = true, ipLookup = true, filePreview = true;
  bool commandCompletion = true;
  bool taskNotifications = true;
  bool desktopHotkey = false;
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
          desktopHotkey = value['desktopHotkey'] == true;
        }
      }
    } catch (_) {
      // Plugin preferences are optional.
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Future<void> save({
    required bool json,
    required bool ip,
    required bool preview,
    bool? completion,
    bool? notifications,
    bool? hotkey,
  }) async {
    jsonFormatter = json;
    ipLookup = ip;
    filePreview = preview;
    commandCompletion = completion ?? commandCompletion;
    taskNotifications = notifications ?? taskNotifications;
    desktopHotkey = hotkey ?? desktopHotkey;
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
        'desktopHotkey': desktopHotkey,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

final pluginSettings = PluginSettings();

class IpLookupResult {
  final String country, region, city, isp, org, timezone;
  const IpLookupResult({
    required this.country,
    required this.region,
    required this.city,
    required this.isp,
    required this.org,
    required this.timezone,
  });
}

Future<IpLookupResult> lookupIp(String ip) async {
  if (!isIpv4(ip)) throw const FormatException('请选择有效的 IPv4 地址');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(Uri.parse('https://ipwho.is/${ip.trim()}'))
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
    return IpLookupResult(
      country: '${value['country'] ?? ''}',
      region: '${value['region'] ?? ''}',
      city: '${value['city'] ?? ''}',
      isp: '${connection['isp'] ?? ''}',
      org: '${connection['org'] ?? ''}',
      timezone: '${timezone['id'] ?? ''}',
    );
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
