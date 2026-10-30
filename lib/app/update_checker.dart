import 'dart:convert';
import 'dart:io';

const appVersion = '1.0.4';
const appBuild = '57';

class UpdateAsset {
  final String name, url;
  const UpdateAsset(this.name, this.url);
}

class UpdateInfo {
  final String version, url, notes;
  final List<UpdateAsset> assets;
  const UpdateInfo({
    required this.version,
    required this.url,
    required this.notes,
    this.assets = const [],
  });

  UpdateAsset? assetFor(String platform) {
    final lower = platform.toLowerCase();
    final matches = assets.where((asset) {
      final name = asset.name.toLowerCase();
      if (lower == 'windows') return name.endsWith('.exe');
      if (lower == 'macos') return name.endsWith('.dmg');
      return false;
    }).toList();
    return matches.isEmpty ? null : matches.first;
  }
}

bool isNewerVersion(String candidate, String current) {
  List<int> parts(String value) => value
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split(RegExp(r'[.+-]'))
      .take(3)
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final a = parts(candidate), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left > right;
  }
  return false;
}

Future<UpdateInfo?> checkForUpdate() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(
      Uri.parse(
        'https://api.github.com/repos/WuBarlynn/W-term/releases/latest',
      ),
    );
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'W-Term/$appVersion');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final value = jsonDecode(await utf8.decoder.bind(response).join());
    if (value is! Map) return null;
    final tag = '${value['tag_name'] ?? ''}';
    final url = '${value['html_url'] ?? ''}';
    if (tag.isEmpty || url.isEmpty || !isNewerVersion(tag, appVersion)) {
      return null;
    }
    return UpdateInfo(version: tag, url: url, notes: '${value['body'] ?? ''}');
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<File> downloadUpdateAsset(UpdateAsset asset) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    var uri = Uri.parse(asset.url);
    for (var redirect = 0; redirect < 5; redirect++) {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'W-Term/$appVersion');
      final response = await request.close();
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) throw StateError('更新下载重定向无效');
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        throw StateError('更新下载失败：HTTP ${response.statusCode}');
      }
      final directory = await Directory.systemTemp.createTemp('wterm-update-');
      final file = File('${directory.path}/${asset.name}');
      final sink = file.openWrite();
      await response.pipe(sink);
      await sink.close();
      return file;
    }
    throw StateError('更新下载重定向过多');
  } finally {
    client.close(force: true);
  }
}
