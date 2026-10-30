import 'dart:convert';
import 'dart:io';

const appVersion = '1.0.2';
const appBuild = '55';

class UpdateInfo {
  final String version, url, notes;
  const UpdateInfo({
    required this.version,
    required this.url,
    required this.notes,
  });
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
