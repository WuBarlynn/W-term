import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/errors.dart';

class RemoteTextEditor extends StatefulWidget {
  final String name, text;
  final Future<void> Function(String) onSave;
  const RemoteTextEditor({
    super.key,
    required this.name,
    required this.text,
    required this.onSave,
  });
  @override
  State<RemoteTextEditor> createState() => _RemoteTextEditorState();
}

class _RemoteTextEditorState extends State<RemoteTextEditor> {
  late final crlf =
      widget.text.contains('\r\n') &&
      !widget.text.replaceAll('\r\n', '').contains('\n');
  late final initial = crlf
      ? widget.text.replaceAll('\r\n', '\n')
      : widget.text;
  late final input = TextEditingController(text: initial);
  bool busy = false, confirming = false;
  String? error;
  bool get dirty => input.text != initial;
  String get content => crlf
      ? input.text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')
      : input.text;
  @override
  void dispose() {
    input.clear();
    input.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (busy || confirming) return;
    if (dirty) {
      confirming = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      confirming = false;
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context, false);
  }

  Future<void> save() async {
    if (busy || !dirty || confirming) return;
    final text = content;
    if (utf8.encode(text).length > 256 * 1024 || text.contains('\x00')) {
      setState(() => error = '仅支持不含空字符、最多 256 KiB 的 UTF-8 文本');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSave(text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: content));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('编辑内容已复制')));
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): save,
      },
      child: AlertDialog(
        title: Text(
          '编辑 ${widget.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 700,
          height:
              (MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom) *
              .52,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'UTF-8 · ${crlf ? "CRLF" : "原始换行"} · 最多 256 KiB',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: input,
                  readOnly: busy,
                  maxLines: null,
                  expands: true,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (error != null)
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : copy, child: const Text('复制内容')),
          TextButton(onPressed: busy ? null : close, child: const Text('关闭')),
          FilledButton(
            onPressed: busy || !dirty ? null : save,
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
