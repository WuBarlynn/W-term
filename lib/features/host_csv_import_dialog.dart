import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/host_import.dart';

class HostCsvImportDialog extends StatefulWidget {
  const HostCsvImportDialog({super.key});
  @override
  State<HostCsvImportDialog> createState() => _HostCsvImportDialogState();
}

class _HostCsvImportDialogState extends State<HostCsvImportDialog> {
  final text = TextEditingController();
  String? error;
  int count = 0, passwordCount = 0;
  String fileName = 'pasted.csv';
  Uint8List? binaryBytes;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> pickFile() async {
    try {
      final file = await openFile();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final lower = file.name.toLowerCase();
      final archive =
          lower.endsWith('.xts') ||
          (bytes.length > 4 &&
              bytes[0] == 0x50 &&
              bytes[1] == 0x4b &&
              bytes[2] == 0x03 &&
              bytes[3] == 0x04);
      if (archive) {
        final bundle = parseHostImportBytesBundle(file.name, bytes);
        final hosts = bundle.hosts;
        setState(() {
          binaryBytes = bytes;
          fileName = file.name;
          text.text =
              '表格备份：${file.name}\n\n'
              '${hosts.take(50).map((host) => '· ${host.name}  ${host.username}@${host.host}:${host.port}').join('\n')}'
              '${hosts.length > 50 ? '\n…' : ''}';
          count = hosts.length;
          passwordCount = bundle.passwords.length;
          error = null;
        });
        return;
      }
      setState(() {
        binaryBytes = null;
        text.text = utf8.decode(bytes, allowMalformed: true);
        fileName = file.name;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '无法读取文件：$e');
    }
  }

  HostImportBundle parseBundle() => binaryBytes != null
      ? parseHostImportBytesBundle(fileName, binaryBytes!)
      : parseHostImportBundle(fileName, text.text);

  void parse() {
    try {
      final bundle = parseBundle();
      setState(() {
        count = bundle.hosts.length;
        passwordCount = bundle.passwords.length;
        error = null;
      });
    } on FormatException catch (e) {
      setState(() {
        count = 0;
        passwordCount = 0;
        error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('从其他平台导入'),
    content: SizedBox(
      width: 640,
      height: 460,
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '支持 CSV/TSV、PuTTY .reg、SecureCRT/MobaXterm .ini、Xshell .xsh/.xts、Excel .xlsx；也可粘贴 CSV',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              OutlinedButton.icon(
                onPressed: pickFile,
                icon: const Icon(Icons.file_open_outlined, size: 16),
                label: const Text('选择文件'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: text,
              expands: true,
              maxLines: null,
              minLines: null,
              autocorrect: false,
              readOnly: binaryBytes != null,
              onChanged: (_) => setState(() {
                binaryBytes = null;
                fileName = 'pasted.csv';
                count = 0;
                passwordCount = 0;
                error = null;
              }),
              decoration: const InputDecoration(
                hintText:
                    'name,host,port,username,group,tags\n'
                    '生产,example.com,22,root,Prod,api',
                alignLabelWithHint: true,
              ),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '可导入 $count 台主机'
                '${passwordCount == 0 ? '' : '，$passwordCount 个密码将存入身份库'}',
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final bundle = parseBundle();
            Navigator.pop<HostImportBundle>(context, bundle);
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        },
        child: const Text('导入'),
      ),
    ],
  );
}
