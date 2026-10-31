import 'dart:convert';
import 'dart:typed_data';

import 'zip_reader.dart';

const maxOfficePreviewBytes = 50 * 1024 * 1024;
const _maxOfficeChars = 300000;

bool isOfficePreviewName(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.docx') ||
      lower.endsWith('.xlsx') ||
      lower.endsWith('.pptx');
}

String? officePreviewText(String path, Uint8List bytes) {
  if (bytes.length > maxOfficePreviewBytes) {
    throw StateError('Office 文件超过 50 MB，请先下载到本地再打开');
  }
  final entries = readZipEntries(bytes);
  final lower = path.toLowerCase();
  if (lower.endsWith('.docx')) {
    final xml = _entryText(entries, 'word/document.xml');
    return xml == null ? null : _clip(_docxText(xml));
  }
  if (lower.endsWith('.pptx')) {
    final slides =
        entries.keys
            .where(
              (name) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(name),
            )
            .toList()
          ..sort((a, b) => _slideNumber(a).compareTo(_slideNumber(b)));
    if (slides.isEmpty) return null;
    final output = StringBuffer();
    for (final slide in slides) {
      final text = _pptxText(_entryText(entries, slide) ?? '');
      if (text.isEmpty) continue;
      output.writeln('--- 幻灯片 ${_slideNumber(slide)} ---');
      output.writeln(text);
      output.writeln();
    }
    return _clip(output.toString().trim());
  }
  if (lower.endsWith('.xlsx')) {
    final shared = <String>[];
    final sharedXml = _entryText(entries, 'xl/sharedStrings.xml');
    if (sharedXml != null) {
      for (final match in RegExp(
        r'<si\b[^>]*>([\s\S]*?)</si>',
      ).allMatches(sharedXml)) {
        shared.add(_xmlText(match.group(1)!));
      }
    }
    final sheet = _entryText(entries, 'xl/worksheets/sheet1.xml');
    if (sheet == null) return null;
    return _clip(_xlsxText(sheet, shared));
  }
  return null;
}

String? _entryText(Map<String, Uint8List> entries, String name) {
  final bytes = entries[name];
  return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
}

int _slideNumber(String name) =>
    int.tryParse(
      RegExp(r'slide(\d+)\.xml$').firstMatch(name)?.group(1) ?? '',
    ) ??
    0;

String _docxText(String xml) {
  final paragraphs = <String>[];
  for (final match in RegExp(r'<w:p\b[^>]*>([\s\S]*?)</w:p>').allMatches(xml)) {
    final raw = match
        .group(1)!
        .replaceAll(RegExp(r'<w:tab\b[^>]*/>'), '\t')
        .replaceAll(RegExp(r'<w:br\b[^>]*/>'), '\n');
    final text = <String>[];
    for (final run in RegExp(r'<w:t\b[^>]*>([\s\S]*?)</w:t>').allMatches(raw)) {
      text.add(_decodeEntities(run.group(1)!));
    }
    paragraphs.add(text.join());
  }
  return paragraphs.join('\n').trim();
}

String _pptxText(String xml) {
  final paragraphs = <String>[];
  for (final match in RegExp(r'<a:p\b[^>]*>([\s\S]*?)</a:p>').allMatches(xml)) {
    final text = <String>[];
    for (final run in RegExp(
      r'<a:t\b[^>]*>([\s\S]*?)</a:t>',
    ).allMatches(match.group(1)!)) {
      text.add(_decodeEntities(run.group(1)!));
    }
    if (text.isNotEmpty) paragraphs.add(text.join());
  }
  return paragraphs.join('\n');
}

String _xlsxText(String xml, List<String> shared) {
  final rows = <String>[];
  for (final row in RegExp(r'<row\b[^>]*>([\s\S]*?)</row>').allMatches(xml)) {
    final cells = <String>[];
    for (final cell in RegExp(
      r'<c\b([^>]*)>([\s\S]*?)</c>',
    ).allMatches(row.group(1)!)) {
      final attrs = cell.group(1)!;
      final body = cell.group(2)!;
      final type = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?.group(1);
      String value;
      if (type == 's') {
        final index = int.tryParse(
          RegExp(r'<v>([\s\S]*?)</v>').firstMatch(body)?.group(1) ?? '',
        );
        value = index != null && index >= 0 && index < shared.length
            ? shared[index]
            : '';
      } else if (type == 'inlineStr') {
        value = _xmlText(body);
      } else {
        value = _decodeEntities(
          RegExp(r'<v>([\s\S]*?)</v>').firstMatch(body)?.group(1) ?? '',
        );
      }
      cells.add(value.replaceAll(RegExp(r'\s+'), ' ').trim());
    }
    if (cells.any((cell) => cell.isNotEmpty)) rows.add(cells.join('\t'));
    if (rows.length >= 500) break;
  }
  return rows.join('\n');
}

String _xmlText(String xml) {
  final text = <String>[];
  for (final match in RegExp(r'<t\b[^>]*>([\s\S]*?)</t>').allMatches(xml)) {
    text.add(_decodeEntities(match.group(1)!));
  }
  return text.join();
}

String _decodeEntities(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&')
    .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (match) {
      final value = int.tryParse(
        match.group(2)!,
        radix: match.group(1)!.isEmpty ? 10 : 16,
      );
      return value == null ? '' : String.fromCharCode(value);
    });

String _clip(String text) => text.length <= _maxOfficeChars
    ? text
    : '${text.substring(0, _maxOfficeChars)}\n…（内容过长，已截断）';
