import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const maxImportedFontBytes = 32 * 1024 * 1024;

bool isSupportedFontBytes(Uint8List bytes) {
  if (bytes.length < 12) return false;
  final tag = String.fromCharCodes(bytes.sublist(0, 4));
  return tag == '\u0000\u0001\u0000\u0000' ||
      tag == 'OTTO' ||
      tag == 'true' ||
      tag == 'ttcf';
}

/// Returns an error message for an unusable family name, or null when valid.
String? validateImportedFontName(String name) {
  final value = name.trim();
  if (value.isEmpty) return '请输入字体名称';
  if (value.length > 64) return '字体名称不能超过 64 个字符';
  if (RegExp(r'[\u0000-\u001f]').hasMatch(value)) {
    return '字体名称不能包含控制字符';
  }
  return null;
}

class ImportedFont {
  final String name;
  final String file;
  const ImportedFont(this.name, this.file);

  Map<String, Object?> toJson() => {'name': name, 'file': file};

  static ImportedFont? fromJson(Map<String, dynamic> value) {
    final name = value['name'];
    final file = value['file'];
    if (name is! String || file is! String || name.trim().isEmpty) {
      return null;
    }
    if (file.contains('/') || file.contains('\\') || file == '..') {
      return null;
    }
    return ImportedFont(name.trim(), file);
  }
}

typedef FontRegistrar = Future<void> Function(String name, Uint8List bytes);

/// User fonts are copied into app support and registered with a local family
/// alias at startup. Nothing is uploaded or shared.
class ImportedFonts extends ChangeNotifier {
  final Future<Directory> Function() _directory;
  final FontRegistrar _register;
  final List<ImportedFont> entries = [];
  Future<void> _pending = Future.value();
  bool loaded = false;

  ImportedFonts({
    Future<Directory> Function()? directory,
    FontRegistrar? register,
  }) : _directory =
           directory ??
           (() async {
             final root = await getApplicationSupportDirectory();
             return Directory('${root.path}/imported_fonts');
           }),
       _register = register ?? _loadWithFlutter;

  List<String> get names => entries.map((entry) => entry.name).toList();

  Future<void> load() async {
    try {
      final directory = await _directory();
      final manifest = File('${directory.path}/fonts.json');
      if (!await manifest.exists()) return;
      final value = jsonDecode(await manifest.readAsString());
      if (value is! Map || value['fonts'] is! List) return;
      final broken = <ImportedFont>[];
      for (final raw in value['fonts'] as List) {
        if (raw is! Map) continue;
        final entry = ImportedFont.fromJson(Map<String, dynamic>.from(raw));
        if (entry == null) continue;
        final fontFile = File('${directory.path}/${entry.file}');
        try {
          if (!await fontFile.exists()) throw StateError('missing');
          final bytes = await fontFile.readAsBytes();
          if (!isSupportedFontBytes(bytes)) throw StateError('invalid');
          await _register(entry.name, bytes);
          entries.add(entry);
        } catch (_) {
          broken.add(entry);
        }
      }
      if (broken.isNotEmpty) await _save(await _directory());
    } catch (_) {
      // A broken import must not block app startup.
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Future<ImportedFont> importFile(File source, String name) async {
    final length = await source.length();
    if (length > maxImportedFontBytes) {
      throw StateError('字体文件不能超过 32 MB');
    }
    final bytes = await source.readAsBytes();
    return _import(bytes, name, source.path.split('.').last);
  }

  Future<ImportedFont> importUrl(Uri uri, String name) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('字体地址必须是 http 或 https');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'W-Term/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw StateError('字体下载失败：HTTP ${response.statusCode}');
      }
      if (response.contentLength > maxImportedFontBytes) {
        throw StateError('字体文件不能超过 32 MB');
      }
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response) {
        total += chunk.length;
        if (total > maxImportedFontBytes) {
          throw StateError('字体文件不能超过 32 MB');
        }
        builder.add(chunk);
      }
      final path = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      final extension = path.contains('.') ? path.split('.').last : 'ttf';
      return await _import(builder.takeBytes(), name, extension);
    } finally {
      client.close(force: true);
    }
  }

  Future<ImportedFont> _import(
    Uint8List bytes,
    String name,
    String extension,
  ) async {
    final error = validateImportedFontName(name);
    if (error != null) throw ArgumentError(error);
    if (!isSupportedFontBytes(bytes)) {
      throw StateError('不是可用的 TTF/OTF 字体文件');
    }
    final safeExtension = switch (extension.toLowerCase()) {
      'otf' => 'otf',
      'ttc' => 'ttc',
      _ => 'ttf',
    };
    final trimmed = name.trim();
    final directory = await _directory();
    await directory.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final fileName = 'font-$stamp.$safeExtension';
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    try {
      await _register(trimmed, bytes);
    } catch (_) {
      await file.delete().catchError((Object _) => file);
      rethrow;
    }
    entries.removeWhere((entry) => entry.name == trimmed);
    final entry = ImportedFont(trimmed, fileName);
    entries.add(entry);
    await _save(directory);
    notifyListeners();
    return entry;
  }

  Future<void> remove(ImportedFont font) async {
    entries.remove(font);
    try {
      final directory = await _directory();
      await File('${directory.path}/${font.file}').delete();
    } catch (_) {
      // The file may already be gone.
    }
    await _save(await _directory());
    notifyListeners();
  }

  Future<void> _save(Directory directory) {
    _pending = _pending.catchError((Object _) {}).then((_) async {
      final manifest = File('${directory.path}/fonts.json');
      await manifest.parent.create(recursive: true);
      final temporary = File('${manifest.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'fonts': entries.map((entry) => entry.toJson()).toList(),
        }),
        flush: true,
      );
      await temporary.rename(manifest.path);
    });
    return _pending;
  }

  static Future<void> _loadWithFlutter(String name, Uint8List bytes) async {
    final loader = FontLoader(name);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

final importedFonts = ImportedFonts();
