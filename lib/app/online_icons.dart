import 'dart:convert';
import 'dart:io';

class OnlineIcon {
  final String name;
  final Uri png;
  const OnlineIcon(this.name, this.png);
}

Uri? onlineIconUrlFromStored(String icon) {
  if (!icon.startsWith('url:')) return null;
  final uri = Uri.tryParse(icon.substring(4));
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

String? onlineIconFromSearchResult(String name) {
  final parts = name.split(':');
  if (parts.length != 2 ||
      !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(parts[0]) ||
      !RegExp(r'^[a-z0-9-]{1,128}$').hasMatch(parts[1])) {
    return null;
  }
  final url = Uri.https('api.iconify.design', '/${parts[0]}/${parts[1]}.png', {
    'height': '64',
    'color': '#4fd1c5',
  });
  return 'url:$url';
}

List<OnlineIcon> parseOnlineIconSearch(String body) {
  if (body.length > 256 * 1024) {
    throw const FormatException('图标搜索结果过大');
  }
  final decoded = jsonDecode(body);
  final rows = decoded is Map ? decoded['icons'] : null;
  if (rows is! List) throw const FormatException('图标搜索格式无效');
  final result = <OnlineIcon>[];
  final seen = <String>{};
  for (final raw in rows) {
    if (result.length >= 60) break;
    if (raw is! String) continue;
    final stored = onlineIconFromSearchResult(raw);
    if (stored == null || !seen.add(raw)) continue;
    result.add(OnlineIcon(raw, Uri.parse(stored.substring(4))));
  }
  if (result.isEmpty) throw const FormatException('没有匹配的在线图标');
  return result;
}

Future<List<OnlineIcon>> searchOnlineIcons(String query) async {
  final value = query.trim();
  if (value.isEmpty || value.length > 80) {
    throw const FormatException('请输入 1–80 个字符的图标关键词');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final uri = Uri.https('api.iconify.design', '/search', {
      'query': value,
      'limit': '48',
    });
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'W-Term');
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('图标搜索返回 HTTP ${response.statusCode}');
    }
    final body = await utf8.decoder.bind(response).join();
    return parseOnlineIconSearch(body);
  } finally {
    client.close(force: true);
  }
}
