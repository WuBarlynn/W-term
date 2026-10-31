import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app/errors.dart';

class ImagePreviewDialog extends StatefulWidget {
  final String title;
  final String path;
  const ImagePreviewDialog({super.key, required this.title, required this.path});

  @override
  State<ImagePreviewDialog> createState() => _ImagePreviewDialogState();
}

class _ImagePreviewDialogState extends State<ImagePreviewDialog> {
  int quarterTurns = 0;
  bool busy = false;
  String message = '';

  Future<void> _save() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final file = File(widget.path);
      if (Platform.isIOS || Platform.isAndroid) {
        final box = context.findRenderObject() as RenderBox;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            fileNameOverrides: [widget.title],
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(suggestedName: widget.title);
        if (location == null) return;
        await file.copy(location.path);
        if (mounted) setState(() => message = '图片已保存：${location.path}');
      }
    } catch (e) {
      if (mounted) setState(() => message = '保存失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title, overflow: TextOverflow.ellipsis),
    content: SizedBox(
      width: 680,
      height: 520,
      child: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              child: RotatedBox(
                quarterTurns: quarterTurns,
                child: Center(
                  child: Image.file(
                    File(widget.path),
                    errorBuilder: (_, _, _) => const Text('无法解码图片'),
                  ),
                ),
              ),
            ),
          ),
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message),
            ),
        ],
      ),
    ),
    actions: [
      IconButton(
        tooltip: '向左旋转',
        onPressed: busy
            ? null
            : () => setState(() => quarterTurns = (quarterTurns + 3) % 4),
        icon: const Icon(Icons.rotate_left),
      ),
      IconButton(
        tooltip: '向右旋转',
        onPressed: busy
            ? null
            : () => setState(() => quarterTurns = (quarterTurns + 1) % 4),
        icon: const Icon(Icons.rotate_right),
      ),
      OutlinedButton.icon(
        onPressed: busy ? null : _save,
        icon: const Icon(Icons.download, size: 18),
        label: const Text('保存/分享'),
      ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
