import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ClipboardImage {
  static const _channel = MethodChannel('dev.wterm/clipboard');

  static Future<void> writePng(Uint8List bytes) async {
    if (Platform.isMacOS || Platform.isIOS) {
      final result = await _channel.invokeMethod<bool>('writePng', bytes);
      if (result != true) throw StateError('系统剪贴板拒绝了图片');
      return;
    }
    if (Platform.isWindows) {
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/wterm-clipboard-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes, flush: true);
      final escaped = file.path.replaceAll("'", "''");
      final script =
          "Add-Type -AssemblyName System.Windows.Forms; "
          "Add-Type -AssemblyName System.Drawing; "
          "\$img=[System.Drawing.Image]::FromFile('$escaped'); "
          "try { [System.Windows.Forms.Clipboard]::SetImage(\$img) } "
          "finally { \$img.Dispose() }";
      try {
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-STA',
          '-Command',
          script,
        ]);
        if (result.exitCode != 0) {
          throw StateError('Windows 剪贴板写入失败');
        }
      } finally {
        await file.delete().catchError((Object _) => file);
      }
      return;
    }
    throw UnsupportedError('当前平台不支持复制图片');
  }
}
