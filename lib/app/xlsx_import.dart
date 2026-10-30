import 'dart:convert';
import 'dart:typed_data';

import 'host_csv.dart';
import 'host_store.dart';
import 'zip_reader.dart';

/// Minimal XLSX reader for host lists: shared strings plus the first worksheet.
/// Formatting, formulas and multiple sheets are intentionally ignored.
List<HostProfile> parseHostXlsx(String fileName, Uint8List bytes) {
  final entries = readZipEntries(bytes);
  final shared = <String>[];
  final sharedFile = entries['xl/sharedStrings.xml'];
  if (sharedFile != null) {
    final xml = utf8.decode(sharedFile, allowMalformed: true);
    for (final match in RegExp(r'<si\b[^>]*>([\s\S]*?)</si>').allMatches(xml)) {
      final texts = <String>[];
      for (final text in RegExp(
        r'<t\b[^>]*>([\s\S]*?)</t>',
      ).allMatches(match.group(1)!)) {
        texts.add(_xmlText(text.group(1)!));
      }
      shared.add(texts.join());
    }
  }
  final sheets =
      entries.keys
          .where(
            (name) =>
                name.startsWith('xl/worksheets/') && name.endsWith('.xml'),
          )
          .toList()
        ..sort();
  if (sheets.isEmpty) throw const FormatException('Excel 文件中没有工作表');
  final sheet = utf8.decode(entries[sheets.first]!, allowMalformed: true);
  final rows = <List<String>>[];
  for (final row in RegExp(r'<row\b[^>]*>([\s\S]*?)</row>').allMatches(sheet)) {
    if (rows.length >= 5000) break;
    final values = <int, String>{};
    for (final cell in RegExp(
      r'<c\b([^>]*)>([\s\S]*?)</c>',
      caseSensitive: false,
    ).allMatches(row.group(1)!)) {
      final attrs = cell.group(1)!;
      final body = cell.group(2)!;
      final reference = RegExp(r'\br="([A-Za-z]+)\d+"').firstMatch(attrs);
      if (reference == null) continue;
      final column = _columnIndex(reference.group(1)!);
      if (column < 0 || column >= 64) continue;
      final type = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?.group(1);
      String value;
      if (type == 's') {
        final index = int.tryParse(
          RegExp(r'<v>\s*(\d+)\s*</v>').firstMatch(body)?.group(1) ?? '',
        );
        value = index != null && index >= 0 && index < shared.length
            ? shared[index]
            : '';
      } else if (type == 'inlineStr') {
        value = RegExp(r'<t\b[^>]*>([\s\S]*?)</t>')
            .allMatches(body)
            .map((match) => _xmlText(match.group(1)!))
            .join();
      } else {
        value = _xmlText(
          RegExp(r'<v>\s*([\s\S]*?)\s*</v>').firstMatch(body)?.group(1) ?? '',
        );
        final number = double.tryParse(value);
        if (number != null && number == number.roundToDouble()) {
          value = '${number.round()}';
        }
      }
      values[column] = value.trim();
    }
    if (values.isEmpty) continue;
    final width = values.keys.reduce((a, b) => a > b ? a : b) + 1;
    final rowValues = List<String>.filled(width, '');
    for (final entry in values.entries) {
      rowValues[entry.key] = entry.value;
    }
    if (rowValues.any((value) => value.isNotEmpty)) rows.add(rowValues);
  }
  if (rows.isEmpty) {
    throw FormatException('Excel 工作表 ${fileName.split('/').last} 没有数据');
  }
  final csv = rows.map((row) => row.map(_csvField).join(',')).join('\n');
  return parseHostCsv(csv);
}

int _columnIndex(String letters) {
  var value = 0;
  for (final rune in letters.toUpperCase().codeUnits) {
    if (rune < 0x41 || rune > 0x5a) return -1;
    value = value * 26 + (rune - 0x41 + 1);
  }
  return value - 1;
}

String _csvField(String value) => '"${value.replaceAll('"', '""')}"';

String _xmlText(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
