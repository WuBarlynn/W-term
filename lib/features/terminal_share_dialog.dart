import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xterm/xterm.dart';

import '../app/errors.dart';

enum ShareImageTemplate { terminal, gradient, plain }

class TerminalShareDialog extends StatefulWidget {
  final String title;
  final List<String> lines;
  final TerminalTheme theme;
  final String fontFamily;
  final double fontSize;
  const TerminalShareDialog({
    super.key,
    required this.title,
    required this.lines,
    required this.theme,
    required this.fontFamily,
    required this.fontSize,
  });

  @override
  State<TerminalShareDialog> createState() => _TerminalShareDialogState();
}

class _TerminalShareDialogState extends State<TerminalShareDialog> {
  final _boundary = GlobalKey();
  late final _title = TextEditingController(text: widget.title);
  ShareImageTemplate template = ShareImageTemplate.terminal;
  late bool dark = widget.theme.background.computeLuminance() < 0.5;
  bool lineNumbers = false;
  bool watermark = true;
  bool busy = false;
  String message = '';

  List<String> get _lines {
    final values = widget.lines
        .map((line) => line.replaceAll('\t', '  '))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    return values.length > 36 ? values.sublist(values.length - 36) : values;
  }

  String _fileName() =>
      'wterm-share-${DateTime.now().millisecondsSinceEpoch}.png';

  Future<Uint8List> _capture() async {
    final boundary =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) throw StateError('无法生成图片');
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('无法生成图片');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _save() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final bytes = await _capture();
      if (Platform.isIOS || Platform.isAndroid) {
        final file = File(
          '${(await getTemporaryDirectory()).path}/${_fileName()}',
        );
        await file.writeAsBytes(bytes, flush: true);
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: _title.text.trim(),
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          ),
        );
        if (mounted) setState(() => message = '已打开系统分享');
      } else {
        final location = await getSaveLocation(
          suggestedName: _fileName(),
          acceptedTypeGroups: const [
            XTypeGroup(label: 'PNG', extensions: ['png']),
          ],
        );
        if (location == null) return;
        await File(location.path).writeAsBytes(bytes, flush: true);
        if (mounted) setState(() => message = '图片已保存：${location.path}');
      }
    } catch (e) {
      if (mounted) setState(() => message = '保存失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _exportText() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final text = widget.lines.join('\n');
      final path = '${(await getTemporaryDirectory()).path}/'
          'wterm-terminal-${DateTime.now().millisecondsSinceEpoch}.txt';
      final file = File(path);
      await file.writeAsString(text, flush: true);
      if (Platform.isIOS || Platform.isAndroid) {
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: _title.text.trim(),
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: 'wterm-terminal.txt',
          acceptedTypeGroups: const [
            XTypeGroup(label: '文本', extensions: ['txt']),
          ],
        );
        if (location == null) return;
        await File(location.path).writeAsString(text, flush: true);
        if (mounted) setState(() => message = '文本已保存：${location.path}');
      }
    } catch (e) {
      if (mounted) setState(() => message = '导出失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _share() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final bytes = await _capture();
      final file = File(
        '${(await getTemporaryDirectory()).path}/${_fileName()}',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: _title.text.trim(),
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => message = '分享失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Color get _background {
    if (template == ShareImageTemplate.terminal) {
      return dark ? const Color(0xff0d1117) : const Color(0xfff6f8fa);
    }
    return dark ? const Color(0xff12161d) : const Color(0xfff8f9fb);
  }

  Color get _foreground =>
      dark ? const Color(0xffe6edf3) : const Color(0xff20242b);

  Widget _preview() {
    final template = this.template;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (template == ShareImageTemplate.terminal)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: dark ? const Color(0xff161b22) : const Color(0xffeaeef2),
            child: Row(
              children: [
                for (final color in const [
                  Color(0xffff5f57),
                  Color(0xfffebc2e),
                  Color(0xff28c840),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: CircleAvatar(radius: 5, backgroundColor: color),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _title.text.isEmpty ? 'W Term' : _title.text,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: dark ? Colors.white70 : Colors.black54,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              _title.text.isEmpty ? 'W Term' : _title.text,
              style: TextStyle(
                color: _foreground,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        for (var index = 0; index < _lines.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lineNumbers)
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _foreground.withValues(alpha: .45),
                        fontFamily: widget.fontFamily,
                        fontSize: widget.fontSize,
                      ),
                    ),
                  ),
                if (lineNumbers) const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _lines[index],
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: TextStyle(
                      color: _foreground,
                      fontFamily: widget.fontFamily,
                      fontSize: widget.fontSize,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (watermark) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'W Term · ${DateTime.now().year}-'
              '${DateTime.now().month.toString().padLeft(2, '0')}-'
              '${DateTime.now().day.toString().padLeft(2, '0')}',
              style: TextStyle(
                color: _foreground.withValues(alpha: .42),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ],
    );
    final decorated = template == ShareImageTemplate.gradient
        ? Container(
            padding: const EdgeInsets.all(26),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? [widget.theme.background, const Color(0xff243447)]
                    : [const Color(0xffffffff), const Color(0xffe3edf7)],
              ),
            ),
            child: body,
          )
        : Container(
            padding: const EdgeInsets.all(26),
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [body],
            ),
          );
    return RepaintBoundary(
      key: _boundary,
      child: Container(
        width: 760,
        color: template == ShareImageTemplate.gradient
            ? Colors.transparent
            : _background,
        child: decorated,
      ),
    );
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860, maxHeight: 760),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '分享为图片',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _title,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in const {
                  ShareImageTemplate.terminal: '终端窗口',
                  ShareImageTemplate.gradient: '渐变卡片',
                  ShareImageTemplate.plain: '极简纯色',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: template == entry.key,
                    onSelected: (_) => setState(() => template = entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('浅色')),
                    ButtonSegment(value: true, label: Text('深色')),
                  ],
                  selected: {dark},
                  onSelectionChanged: (value) =>
                      setState(() => dark = value.first),
                ),
                FilterChip(
                  label: const Text('行号'),
                  selected: lineNumbers,
                  onSelected: (value) => setState(() => lineNumbers = value),
                ),
                FilterChip(
                  label: const Text('水印'),
                  selected: watermark,
                  onSelected: (value) => setState(() => watermark = value),
                ),
              ],
            ),
            const SizedBox(height: 14),
            HorizontalSingleChildScrollView(
              child: _preview(),
            ),
            if (message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(message),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: busy ? null : _exportText,
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('导出文本'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: busy ? null : _share,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('分享'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: busy ? null : _save,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download, size: 18),
                  label: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class HorizontalSingleChildScrollView extends StatelessWidget {
  final Widget child;
  const HorizontalSingleChildScrollView({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: child);
}
