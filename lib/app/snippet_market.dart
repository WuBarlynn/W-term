import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'snippet_store.dart';

bool _safeRemoteCommand(String command) {
  if (validateSnippetCommand(command) != null) return false;
  final normalized = command.replaceAll(
    RegExp(r'2>\s*/dev/null|2>&1|>\s*/dev/null|</dev/null'),
    '',
  );
  return !RegExp(r'(^|[^0-9])>|\$\(|`|&&|\|\||;').hasMatch(normalized);
}

class MarketSnippet {
  final String name, category, command;
  const MarketSnippet(this.name, this.category, this.command);
}

const snippetMarketUrl =
    'https://raw.githubusercontent.com/WuBarlynn/W-term/main/docs/snippet-market.json';

/// Validates a remote catalog without trusting it: commands must be single-line
/// and non-destructive validation is left to the normal snippet editor flow.
List<MarketSnippet> parseSnippetMarket(String body) {
  if (body.length > 256 * 1024) {
    throw const FormatException('片段市场数据超过 256 KiB');
  }
  final decoded = jsonDecode(body);
  final rows = decoded is Map ? decoded['snippets'] : decoded;
  if (rows is! List) throw const FormatException('片段市场格式无效');
  final result = <MarketSnippet>[];
  final seen = <String>{};
  for (final raw in rows) {
    if (result.length >= 200) break;
    if (raw is! Map) continue;
    final name = '${raw['name'] ?? ''}'.trim();
    final category = '${raw['category'] ?? ''}'.trim();
    final command = '${raw['command'] ?? ''}'.trim();
    if (name.isEmpty ||
        name.length > 256 ||
        category.isEmpty ||
        category.length > 64 ||
        command.isEmpty ||
        !_safeRemoteCommand(command)) {
      continue;
    }
    final key = '$name\u0000$command';
    if (!seen.add(key)) continue;
    result.add(MarketSnippet(name, category, command));
  }
  if (result.isEmpty) throw const FormatException('片段市场没有可用片段');
  return result;
}

class SnippetMarket {
  final Future<File> Function() _cacheFile;
  final Future<String> Function(Uri uri)? fetcher;

  SnippetMarket({Future<File> Function()? cacheFile, this.fetcher})
    : _cacheFile =
          cacheFile ??
          (() async => File(
            '${(await getApplicationSupportDirectory()).path}/snippet-market.json',
          ));

  Future<String> _download(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'W-Term');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        throw StateError('片段市场返回 HTTP ${response.statusCode}');
      }
      final body = await utf8.decoder.bind(response).join();
      if (body.length > 256 * 1024) {
        throw const FormatException('片段市场数据超过 256 KiB');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<MarketSnippet>> load({bool refresh = false}) async {
    final file = await _cacheFile();
    if (!refresh && await file.exists()) {
      try {
        return parseSnippetMarket(await file.readAsString());
      } catch (_) {
        // A damaged cache should not block a remote refresh.
      }
    }
    final body = await (fetcher != null
        ? fetcher!(Uri.parse(snippetMarketUrl))
        : _download(Uri.parse(snippetMarketUrl)));
    final entries = parseSnippetMarket(body);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(body, flush: true);
    await temporary.rename(file.path);
    return entries;
  }
}

final snippetMarket = SnippetMarket();
