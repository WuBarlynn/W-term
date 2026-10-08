import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../app/host_store.dart';
import '../app/openssh_config.dart';
import '../app/errors.dart';

class OpenSshImportDialog extends StatefulWidget {
  final HostStore store;
  final String initialSource;
  const OpenSshImportDialog({
    super.key,
    required this.store,
    this.initialSource = '',
  });
  @override
  State<OpenSshImportDialog> createState() => _OpenSshImportDialogState();
}

class _OpenSshImportDialogState extends State<OpenSshImportDialog> {
  late final source = TextEditingController(text: widget.initialSource);
  final username = TextEditingController();
  List<SshImportEntry>? entries;
  final selected = <String>{};
  String? error;
  bool busy = false;
  @override
  void dispose() {
    source.dispose();
    username.dispose();
    super.dispose();
  }

  void invalidate() => setState(() {
    entries = null;
    selected.clear();
    error = null;
  });
  Future<void> chooseFile() async {
    setState(() => busy = true);
    try {
      final file = await openFile();
      if (file == null) return;
      if (await file.length() > 65536) {
        throw const FormatException('配置文件不能超过 64 KiB');
      }
      final text = await file.readAsString();
      if (mounted) {
        source.text = text;
        invalidate();
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void preview() {
    try {
      final parsed = parseOpenSshConfig(
        source.text,
        defaultUsername: username.text,
      );
      setState(() {
        entries = parsed;
        selected
          ..clear()
          ..addAll(parsed.where((e) => e.canImport).map((e) => e.alias));
        error = parsed.isEmpty ? '未找到具体 Host 名称；通配符仅用作默认规则。' : null;
      });
    } catch (e) {
      setState(() {
        entries = null;
        selected.clear();
        error = userFacingError(e);
      });
    }
  }

  Future<void> save() async {
    if (busy || entries == null || selected.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final count = await importSshEntries(
        widget.store,
        entries!.where((e) => selected.contains(e.alias)).toList(),
      );
      if (mounted) Navigator.pop(context, count);
    } catch (e) {
      if (mounted) setState(() => error = '导入失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('导入 OpenSSH 配置'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '导入 Host、HostName、User 和 Port，保存到“OpenSSH 导入”分类。相同配置跳过，现有主机不覆盖。',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: busy ? null : chooseFile,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('选择配置文件'),
            ),
            TextField(
              controller: source,
              enabled: !busy,
              minLines: 4,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '或粘贴配置内容'),
              onChanged: (_) => invalidate(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: username,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '默认用户名（配置缺少 User 时使用）',
              ),
              onChanged: (_) => invalidate(),
            ),
            const SizedBox(height: 12),
            const Text(
              'IdentityFile 仅作为提示，不自动读取私钥；导入后在主机编辑中选择身份。其他未支持选项会阻止对应主机导入，Include/Match 暂不支持。',
              style: TextStyle(fontSize: 12),
            ),
            TextButton(
              onPressed: busy ? null : preview,
              child: const Text('预览配置'),
            ),
            if (entries != null) ...[
              Text('选择 ${selected.length} / ${entries!.length} 台主机'),
              for (final e in entries!)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: selected.contains(e.alias),
                  onChanged: busy || !e.canImport
                      ? null
                      : (checked) => setState(() {
                          if (checked!) {
                            selected.add(e.alias);
                          } else {
                            selected.remove(e.alias);
                          }
                        }),
                  title: Text(e.alias),
                  subtitle: Text(
                    [
                      '${e.username}@${e.hostname}:${e.port}',
                      ...e.issues,
                      if (e.identityFiles.isNotEmpty)
                        '需手动选择私钥：${e.identityFiles.join(', ')}',
                    ].join('\n'),
                  ),
                ),
            ],
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy || selected.isEmpty ? null : save,
          child: Text('导入 ${selected.length} 台'),
        ),
      ],
    ),
  );
}
