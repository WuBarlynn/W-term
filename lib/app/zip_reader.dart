import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads the central directory of a ZIP archive. Only stored and deflated
/// entries are supported, which covers Xshell `.xts` backups.
Map<String, Uint8List> readZipEntries(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  int? directoryOffset, entryCount;
  for (
    var i = bytes.length - 22;
    i >= 0 && i >= bytes.length - 22 - 65535;
    i--
  ) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      entryCount = data.getUint16(i + 10, Endian.little);
      directoryOffset = data.getUint32(i + 16, Endian.little);
      break;
    }
  }
  if (directoryOffset == null || entryCount == null) {
    throw const FormatException('不是有效的 ZIP/XTS 压缩包');
  }
  final entries = <String, Uint8List>{};
  var offset = directoryOffset;
  for (var index = 0; index < entryCount; index++) {
    if (offset + 46 > bytes.length ||
        data.getUint32(offset, Endian.little) != 0x02014b50) {
      break;
    }
    final method = data.getUint16(offset + 10, Endian.little);
    final compressed = data.getUint32(offset + 20, Endian.little);
    final uncompressed = data.getUint32(offset + 24, Endian.little);
    final nameLength = data.getUint16(offset + 28, Endian.little);
    final extraLength = data.getUint16(offset + 30, Endian.little);
    final commentLength = data.getUint16(offset + 32, Endian.little);
    final localOffset = data.getUint32(offset + 42, Endian.little);
    final nameStart = offset + 46;
    final nameEnd = nameStart + nameLength;
    if (nameEnd > bytes.length) break;
    final name = utf8.decode(
      bytes.sublist(nameStart, nameEnd),
      allowMalformed: true,
    );
    offset = nameEnd + extraLength + commentLength;
    if (name.endsWith('/')) continue;
    if (localOffset + 30 > bytes.length ||
        data.getUint32(localOffset, Endian.little) != 0x04034b50) {
      continue;
    }
    final localNameLength = data.getUint16(localOffset + 26, Endian.little);
    final localExtraLength = data.getUint16(localOffset + 28, Endian.little);
    final dataStart = localOffset + 30 + localNameLength + localExtraLength;
    final dataEnd = dataStart + compressed;
    if (dataEnd > bytes.length) continue;
    final raw = bytes.sublist(dataStart, dataEnd);
    try {
      if (method == 0) {
        entries[name] = Uint8List.fromList(raw);
      } else if (method == 8) {
        final decoded = ZLibDecoder(raw: true).convert(raw);
        if (decoded.length != uncompressed) continue;
        entries[name] = Uint8List.fromList(decoded);
      }
    } catch (_) {
      // A damaged member must not hide the remaining sessions.
    }
  }
  if (entries.isEmpty) throw const FormatException('压缩包中没有可读取的文件');
  return entries;
}
