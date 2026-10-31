import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/office_preview.dart';

List<int> u16(int value) => [value & 0xff, (value >> 8) & 0xff];
List<int> u32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

Uint8List storedZip(Map<String, String> files) {
  final local = <int>[];
  final central = <int>[];
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = utf8.encode(entry.value);
    final offset = local.length;
    local
      ..addAll(u32(0x04034b50))
      ..addAll(u16(20))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u32(0))
      ..addAll(u32(data.length))
      ..addAll(u32(data.length))
      ..addAll(u16(name.length))
      ..addAll(u16(0))
      ..addAll(name)
      ..addAll(data);
    central
      ..addAll(u32(0x02014b50))
      ..addAll(u16(20))
      ..addAll(u16(20))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u32(0))
      ..addAll(u32(data.length))
      ..addAll(u32(data.length))
      ..addAll(u16(name.length))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u16(0))
      ..addAll(u32(0))
      ..addAll(u32(offset))
      ..addAll(name);
  }
  final centralOffset = local.length;
  final bytes = <int>[...local, ...central];
  bytes
    ..addAll(u32(0x06054b50))
    ..addAll(u16(0))
    ..addAll(u16(0))
    ..addAll(u16(files.length))
    ..addAll(u16(files.length))
    ..addAll(u32(central.length))
    ..addAll(u32(centralOffset))
    ..addAll(u16(0));
  return Uint8List.fromList(bytes);
}

void main() {
  test('docx paragraphs are extracted with entities decoded', () {
    final bytes = storedZip({
      'word/document.xml':
          '<w:document><w:body>'
          '<w:p><w:r><w:t>Hello</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>World &amp; Co</w:t></w:r></w:p>'
          '</w:body></w:document>',
    });
    expect(officePreviewText('notes.docx', bytes), 'Hello\nWorld & Co');
  });

  test('xlsx shared strings and numeric cells become a tab table', () {
    final bytes = storedZip({
      'xl/sharedStrings.xml':
          '<sst><si><t>Name</t></si><si><t>Alice</t></si></sst>',
      'xl/worksheets/sheet1.xml':
          '<worksheet><sheetData>'
          '<row><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
          '<row><c r="A2"><v>42</v></c></row>'
          '</sheetData></worksheet>',
    });
    expect(officePreviewText('report.xlsx', bytes), 'Name\tAlice\n42');
  });

  test('pptx slides are ordered and separated', () {
    final bytes = storedZip({
      'ppt/slides/slide2.xml':
          '<p:sld><a:p><a:r><a:t>Second</a:t></a:r></a:p></p:sld>',
      'ppt/slides/slide1.xml':
          '<p:sld><a:p><a:r><a:t>First</a:t></a:r></a:p></p:sld>',
    });
    final text = officePreviewText('deck.pptx', bytes)!;
    expect(text.indexOf('First'), lessThan(text.indexOf('Second')));
    expect(text, contains('--- 幻灯片 1 ---'));
    expect(text, contains('--- 幻灯片 2 ---'));
  });

  test('legacy Office files are not claimed by the inline preview', () {
    expect(isOfficePreviewName('report.docx'), isTrue);
    expect(isOfficePreviewName('report.XLSX'), isTrue);
    expect(isOfficePreviewName('report.ppt'), isFalse);
    expect(isOfficePreviewName('report.doc'), isFalse);
  });
}
