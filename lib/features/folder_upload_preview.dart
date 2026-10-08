import 'package:flutter/material.dart';

import '../app/folder_upload.dart';

String folderBytesLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

class FolderUploadPreview extends StatefulWidget {
  final List<FolderUploadItem> items;
  final String destination;
  const FolderUploadPreview({
    super.key,
    required this.items,
    required this.destination,
  });

  @override
  State<FolderUploadPreview> createState() => _FolderUploadPreviewState();
}

class _FolderUploadPreviewState extends State<FolderUploadPreview> {
  late final name = TextEditingController(
    text: widget.items.isEmpty ? '' : widget.items.first.relativePath,
  );
  final form = GlobalKey<FormState>();
  bool includeHidden = true;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = selectFolderUploadItems(
      widget.items,
      includeHidden: includeHidden,
    );
    final destination = widget.destination;
    final files = items.where((item) => !item.isDirectory).length;
    final bytes = items.fold<int>(0, (sum, item) => sum + item.scannedBytes);
    return AlertDialog(
      title: const Text('上传文件夹？'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '目标：$destination',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: '目标文件夹名称'),
                autocorrect: false,
                validator: (v) => validateUploadFolderName(v ?? ''),
                onChanged: (_) => setState(() {}),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('包含隐藏文件和子文件夹'),
                subtitle: const Text('取消勾选将排除名称以点开头的子项目'),
                value: includeHidden,
                onChanged: (value) =>
                    setState(() => includeHidden = value ?? true),
              ),
              const SizedBox(height: 8),
              Text(
                '$files 个文件 · ${items.length - files} 个文件夹 · ${folderBytesLabel(bytes)}',
              ),
              const SizedBox(height: 8),
              const Text(
                '大小为扫描时统计。保留空目录，已有同名根目录时拒绝上传；失败或取消保留已上传内容。',
                style: TextStyle(fontSize: 12),
              ),
              const Divider(),
              SizedBox(
                height: 200,
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final displayPath =
                        '${name.text}${item.relativePath.substring(items.first.relativePath.length)}';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        item.isDirectory
                            ? Icons.folder_outlined
                            : Icons.insert_drive_file_outlined,
                        size: 20,
                      ),
                      title: Tooltip(
                        message: displayPath,
                        child: Text(
                          displayPath,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      subtitle: item.isDirectory
                          ? null
                          : Text(folderBytesLabel(item.scannedBytes)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: items.isEmpty
              ? null
              : () {
                  if (form.currentState!.validate()) {
                    Navigator.pop(
                      context,
                      FolderUploadSelection(
                        name.text,
                        includeHidden: includeHidden,
                      ),
                    );
                  }
                },
          child: const Text('上传'),
        ),
      ],
    );
  }
}
